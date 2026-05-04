#!/usr/bin/env python3
"""
IoTSound Karaoke Fetcher — yt-dlp download service.
Exposes a small HTTP API for the karaoke container.
Self-updates yt-dlp nightly via APScheduler.
"""
import logging
import os
import re
import subprocess
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from flask import Flask, request, jsonify
from apscheduler.schedulers.background import BackgroundScheduler
from waitress import serve

LOG_LEVEL = os.environ.get('KARAOKE_LOG_LEVEL', os.environ.get('LOG_LEVEL', 'info')).upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format='[fetcher] %(levelname)s %(message)s',
)
log = logging.getLogger(__name__)

app = Flask(__name__)
executor = ThreadPoolExecutor(max_workers=2)

MEDIA_PATH = os.environ.get('MEDIA_PATH', '/data/media')
QUALITY    = os.environ.get('KARAOKE_QUALITY', '720')

jobs: dict = {}
jobs_lock = threading.Lock()

PROGRESS_RE = re.compile(r'\s*(\d{1,3}(?:\.\d+)?)%')


# ── Endpoints ────────────────────────────────────────────────────────────────

@app.route('/fetch', methods=['POST'])
def fetch():
    data = request.get_json(force=True)
    url = (data or {}).get('url', '')
    if not url:
        return jsonify({'error': 'url required'}), 400
    job_id = str(uuid.uuid4())
    with jobs_lock:
        jobs[job_id] = {'status': 'pending', 'progress': '0%', 'filepath': '', 'error': ''}
    executor.submit(_download, job_id, url)
    return jsonify({'job_id': job_id})


@app.route('/status/<job_id>')
def status(job_id):
    with jobs_lock:
        job = jobs.get(job_id)
    if not job:
        return jsonify({'error': 'not found'}), 404
    return jsonify(job)


@app.route('/info/<yt_id>')
def info(yt_id):
    url = f'https://www.youtube.com/watch?v={yt_id}'
    try:
        result = subprocess.run(
            ['yt-dlp', '--print',
             '%(title)s<|>%(duration_string)s<|>%(filesize_approx)s<|>%(thumbnail)s',
             '--no-download', '--no-warnings', url],
            capture_output=True, text=True, timeout=15
        )
        parts = result.stdout.strip().split('<|>')
        return jsonify({
            'title':           parts[0] if len(parts) > 0 else '',
            'duration':        parts[1] if len(parts) > 1 else '',
            'filesize_approx': int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0,
            'thumbnail':       parts[3] if len(parts) > 3 else '',
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/health')
def health():
    result = subprocess.run(['yt-dlp', '--version'], capture_output=True, text=True)
    return jsonify({'yt_dlp_version': result.stdout.strip(), 'status': 'ok'})


# ── Download worker ───────────────────────────────────────────────────────────

def _download(job_id: str, url: str):
    with jobs_lock:
        jobs[job_id]['status'] = 'downloading'

    out_tmpl = os.path.join(MEDIA_PATH, '%(title)s.%(ext)s')
    cmd = [
        'yt-dlp', '--newline', '--no-playlist',
        '-f', f'best[height<={QUALITY}]/bestvideo[height<={QUALITY}]+bestaudio/best',
        '--js-runtimes', 'node',
        '-o', out_tmpl,
        '--print', 'after_move:filepath',
        url,
    ]
    if os.path.exists('cookies.txt'):
        cmd += ['--cookies', 'cookies.txt']

    log.info('Downloading %s', url)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    filepath = ''

    for line in proc.stdout:
        line = line.strip()
        m = PROGRESS_RE.search(line)
        if m:
            with jobs_lock:
                jobs[job_id]['progress'] = m.group(1) + '%'
        elif line.startswith('/'):
            filepath = line
        elif 'Finalizing' in line:
            with jobs_lock:
                jobs[job_id]['progress'] = 'Finalizing'

    proc.wait()

    with jobs_lock:
        if proc.returncode == 0 and filepath:
            jobs[job_id].update({'status': 'done', 'progress': '100%', 'filepath': filepath})
            log.info('Done: %s', filepath)
        else:
            err = proc.stderr.read() if proc.stderr else 'unknown error'
            jobs[job_id].update({'status': 'failed', 'error': str(err)[:200]})
            log.error('Failed: %s', url)


# ── Nightly yt-dlp update ─────────────────────────────────────────────────────

def _update_ytdlp():
    log.info('Updating yt-dlp...')
    subprocess.run([
        'pip', '--disable-pip-version-check',
        'install', '--upgrade', 'yt-dlp', '-q',
        '--root-user-action=ignore',
    ], check=False)
    log.info('yt-dlp updated')


# ── Entry point ───────────────────────────────────────────────────────────────

def start_services():
    os.makedirs(MEDIA_PATH, exist_ok=True)

    scheduler = BackgroundScheduler()
    scheduler.add_job(_update_ytdlp, 'cron', hour=3, minute=0)
    scheduler.start()
    return scheduler


if __name__ == '__main__':
    start_services()
    log.info('Karaoke fetcher listening on :8081')
    serve(app, host='0.0.0.0', port=8081, threads=4)
