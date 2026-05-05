package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	_ "modernc.org/sqlite"
)

// ── Config ───────────────────────────────────────────────────────────────────

const (
	downloadPath = "/data/media"
	dataPath     = "/data/app"
	fetcherBase  = "http://karaoke-fetcher:8081"

	karaokeMicLoopbackName = "karaoke-mic-loopback"
)

var (
	listenPort   = envOr("KARAOKE_PORT", ":8080")
	soundSuper   = envOr("SOUND_SUPERVISOR_URL", "http://172.17.0.1:80")
	quality      = envOr("KARAOKE_QUALITY", "720")
	maxPerSinger = envIntOr("KARAOKE_MAX_QUEUE_PER_SINGER", 3)
	logLevel     = parseLogLevel(envOr("KARAOKE_LOG_LEVEL", envOr("LOG_LEVEL", "info")))
)

// ── Types ────────────────────────────────────────────────────────────────────

type Job struct {
	ID        int64  `json:"id"`
	YtID      string `json:"yt_id"`
	Status    string `json:"status"`
	Title     string `json:"title"`
	Singer    string `json:"singer"`
	Filename  string `json:"filename"`
	Progress  string `json:"progress"`
	KeyOffset int    `json:"key_offset"`
	Locked    bool   `json:"locked"`
	Thumbnail string `json:"thumbnail"`
	Duration  string `json:"duration"`
}

type Singer struct {
	Name      string `json:"name"`
	KeyOffset int    `json:"key_offset"`
	Volume    int    `json:"volume"`
	LastSeen  string `json:"last_seen"`
}

type SearchResult struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Uploader string `json:"uploader"`
	Duration string `json:"duration"`
	URL      string `json:"url"`
	Thumb    string `json:"thumb"`
}

type APIData struct {
	NowPlaying     *Job   `json:"now_playing"`
	NextUp         *Job   `json:"next_up"`
	Queue          []*Job `json:"queue"`
	History        []*Job `json:"history"`
	State          string `json:"state"`
	UpNextUntil    int64  `json:"up_next_until"`    // unix ms; non-zero only in up_next state
	PlayPositionMs int64  `json:"play_position_ms"` // ms elapsed since current song started
	AudioMode      string `json:"audio_mode"`
	SyncOffsetMs   int    `json:"sync_offset_ms"`
	MicGain        int    `json:"mic_gain"`
	MicAvailable   bool   `json:"mic_available"`
}

// ── Globals ──────────────────────────────────────────────────────────────────

var (
	db               *sql.DB
	downloadProgress sync.Map  // int64 id → string progress
	playerCmd        *exec.Cmd // PipeWire audio process
	playerMu         sync.Mutex
	micLoopbackMu    sync.Mutex
)

type logSeverity int

const (
	logDebug logSeverity = iota
	logInfo
	logWarn
	logError
)

func parseLogLevel(level string) logSeverity {
	switch strings.ToLower(strings.TrimSpace(level)) {
	case "debug":
		return logDebug
	case "warn", "warning":
		return logWarn
	case "error":
		return logError
	default:
		return logInfo
	}
}

func logAt(level logSeverity, format string, args ...any) {
	if logLevel <= level {
		log.Printf(format, args...)
	}
}

func logDebugf(format string, args ...any) { logAt(logDebug, format, args...) }
func logInfof(format string, args ...any)  { logAt(logInfo, format, args...) }
func logWarnf(format string, args ...any)  { logAt(logWarn, format, args...) }
func logErrorf(format string, args ...any) { logAt(logError, format, args...) }

// current song file served at /stream/current
var (
	currentFile   string
	currentFileMu sync.RWMutex
)

// between-songs transition state
var (
	playerState   = "idle" // "idle", "playing", "up_next"
	upNextUntil   time.Time
	upNextSinger  string
	upNextTitle   string
	songStartTime time.Time
	stateMu       sync.Mutex
)

// audio routing mode (not persisted; resets to "local" on restart)
var (
	audioMode   = "local"
	audioModeMu sync.RWMutex
)

// modeChangeCh is signalled when audioMode changes during playback.
var modeChangeCh = make(chan struct{}, 1)

// syncChangeCh is signalled when A/V sync changes during playback.
var syncChangeCh = make(chan struct{}, 1)

// skipCh is signalled when the current song should end immediately.
var skipCh = make(chan struct{}, 1)

// ── Main ─────────────────────────────────────────────────────────────────────

func main() {
	for _, p := range []string{downloadPath, dataPath} {
		if err := os.MkdirAll(p, 0755); err != nil {
			log.Fatalf("mkdir %s: %v", p, err)
		}
	}
	initDB()
	resetStaleJobs()
	go cleanupIdleMicLoopback()

	go downloadWorker()
	go playerWorker()

	mux := http.NewServeMux()
	registerRoutes(mux)

	logInfof("[karaoke] Listening on %s", listenPort)
	logDebugf("[karaoke] debug logging enabled")
	log.Fatal(http.ListenAndServe(listenPort, mux))
}

func cleanupIdleMicLoopback() {
	time.Sleep(5 * time.Second)
	if err := disableMicLoopback(); err != nil {
		logDebugf("[mic] idle loopback cleanup skipped: %v", err)
	}
}

// ── Routes ───────────────────────────────────────────────────────────────────

func registerRoutes(mux *http.ServeMux) {
	// Pages
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "static/index.html")
	})
	mux.HandleFunc("GET /singer/{name}", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "static/singer.html")
	})
	mux.HandleFunc("GET /singer-stream", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "static/stream.html")
	})
	mux.HandleFunc("GET /sync", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "static/sync.html")
	})
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServer(http.Dir("static"))))

	// Current song stream (direct MP4 — no ffmpeg encoding on Pi)
	mux.HandleFunc("GET /stream/current", handleCurrentStream)

	// Queue API
	mux.HandleFunc("GET /api/data", handleAPIData)
	mux.HandleFunc("POST /add", handleAdd)
	mux.HandleFunc("POST /skip", handleSkip)
	mux.HandleFunc("POST /delete", handleDelete)
	mux.HandleFunc("POST /api/queue/{id}/key", handleQueueKey)
	mux.HandleFunc("POST /api/history/delete", handleDeleteHistory)

	// Search
	mux.HandleFunc("GET /api/search", handleSearch)

	// Singer profiles
	mux.HandleFunc("GET /api/singer/{name}", handleGetSinger)
	mux.HandleFunc("PUT /api/singer/{name}", handleUpdateSinger)
	mux.HandleFunc("POST /api/singer/{name}/favorites", handleToggleFavorite)

	// Volume (proxied to sound-supervisor)
	mux.HandleFunc("GET /api/volume", handleGetVolume)
	mux.HandleFunc("POST /api/volume", handleSetVolume)
	mux.HandleFunc("GET /api/mic-gain", handleGetMicGain)
	mux.HandleFunc("POST /api/mic-gain", handleSetMicGain)

	// Sync offset (Phase 2 — endpoints wired, implementation in player)
	mux.HandleFunc("GET /api/sync", handleGetSync)
	mux.HandleFunc("POST /api/sync", handleSetSync)

	// Storage
	mux.HandleFunc("GET /api/storage", handleStorageStats)
	mux.HandleFunc("POST /api/storage/quota", handleSetQuota)

	// Audio mode
	mux.HandleFunc("GET /api/audio-mode", handleGetAudioMode)
	mux.HandleFunc("POST /api/audio-mode", handleSetAudioMode)

	// QR code (PNG for join URL)
	mux.HandleFunc("GET /api/qr", handleQR)

	// System
	mux.HandleFunc("POST /api/shutdown", handleShutdown)
}

// ── DB ───────────────────────────────────────────────────────────────────────

func initDB() {
	dbPath := filepath.Join(dataPath, "karaoke.db")
	var err error
	db, err = sql.Open("sqlite", dbPath+"?_journal_mode=WAL&_busy_timeout=5000")
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`
	CREATE TABLE IF NOT EXISTS jobs (
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		yt_id      TEXT    DEFAULT '',
		url        TEXT    DEFAULT '',
		status     TEXT    NOT NULL,
		title      TEXT    DEFAULT '',
		singer     TEXT    DEFAULT '',
		filename   TEXT    DEFAULT '',
		progress   TEXT    DEFAULT '',
		key_offset INTEGER DEFAULT 0,
		locked     INTEGER DEFAULT 0,
		thumbnail  TEXT    DEFAULT '',
		duration   TEXT    DEFAULT '',
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);
	CREATE TABLE IF NOT EXISTS singers (
		name       TEXT PRIMARY KEY,
		key_offset INTEGER DEFAULT 0,
		volume     INTEGER DEFAULT 80,
		last_seen  DATETIME DEFAULT CURRENT_TIMESTAMP
	);
	CREATE TABLE IF NOT EXISTS singer_history (
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		singer     TEXT,
		yt_id      TEXT,
		title      TEXT    DEFAULT '',
		thumbnail  TEXT    DEFAULT '',
		key_offset INTEGER DEFAULT 0,
		play_count INTEGER DEFAULT 1,
		played_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
		UNIQUE(singer, yt_id) ON CONFLICT REPLACE
	);
	CREATE TABLE IF NOT EXISTS singer_favorites (
		singer    TEXT,
		yt_id     TEXT,
		title     TEXT    DEFAULT '',
		thumbnail TEXT    DEFAULT '',
		added_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY (singer, yt_id)
	);
	CREATE TABLE IF NOT EXISTS config (
		key   TEXT PRIMARY KEY,
		value TEXT DEFAULT ''
	);`)
	if err != nil {
		log.Fatalf("schema: %v", err)
	}
}

func resetStaleJobs() {
	db.Exec(`UPDATE jobs SET status='played' WHERE status IN ('playing','downloading','pending')`)
}

// ── Queue Handlers ───────────────────────────────────────────────────────────

func handleAPIData(w http.ResponseWriter, r *http.Request) {
	lockUpcoming()

	stateMu.Lock()
	state := playerState
	until := upNextUntil
	uSinger := upNextSinger
	uTitle := upNextTitle
	stateMu.Unlock()

	audioModeMu.RLock()
	mode := audioMode
	audioModeMu.RUnlock()
	syncOffsetMs := syncOffset()
	micGain := micGain()
	micAvailable := false
	if _, err := micSource(); err == nil {
		micAvailable = true
	}

	now := queryByStatus("playing", 1)

	// Next Up = first queued job in any active state (not just ready).
	// This ensures a downloading song shows as Next Up immediately.
	nextUpList := queryMultiStatusLimited([]string{"ready", "downloading", "pending"}, 1)

	var nowPlaying, nextUp *Job
	if len(now) > 0 {
		nowPlaying = now[0]
	}
	if nowPlaying == nil && state == "playing" {
		state = "idle"
	}
	if len(nextUpList) > 0 {
		nextUp = nextUpList[0]
	}
	// During up_next transition synthesize from state if DB hasn't caught up yet
	if state == "up_next" && nextUp == nil && uSinger != "" {
		nextUp = &Job{Singer: uSinger, Title: uTitle}
	}

	// Full queue view: everything after Next Up
	all := queryMultiStatus([]string{"pending", "downloading", "ready"})
	queue := make([]*Job, 0, len(all))
	for _, j := range all {
		if nextUp != nil && j.ID == nextUp.ID {
			continue
		}
		queue = append(queue, j)
	}

	singer := r.URL.Query().Get("singer")
	filter := r.URL.Query().Get("history_filter")
	history := queryHistory(singer, filter, 60)

	upNextMs := int64(0)
	if state == "up_next" {
		upNextMs = until.UnixMilli()
	}

	stateMu.Lock()
	posMs := int64(0)
	if state == "playing" {
		posMs = time.Since(songStartTime).Milliseconds()
	}
	stateMu.Unlock()

	writeJSON(w, APIData{
		NowPlaying:     nowPlaying,
		NextUp:         nextUp,
		Queue:          queue,
		History:        history,
		State:          state,
		UpNextUntil:    upNextMs,
		PlayPositionMs: posMs,
		AudioMode:      mode,
		SyncOffsetMs:   syncOffsetMs,
		MicGain:        micGain,
		MicAvailable:   micAvailable,
	})
}

func handleAdd(w http.ResponseWriter, r *http.Request) {
	r.ParseForm()
	singer := strings.TrimSpace(r.FormValue("singer"))
	url := strings.TrimSpace(r.FormValue("url"))
	title := strings.TrimSpace(r.FormValue("title"))
	thumbnail := strings.TrimSpace(r.FormValue("thumbnail"))
	ytID := strings.TrimSpace(r.FormValue("yt_id"))
	duration := strings.TrimSpace(r.FormValue("duration"))

	if singer == "" || url == "" {
		http.Error(w, "singer and url required", http.StatusBadRequest)
		return
	}

	// Per-singer queue limit
	var inQueue int
	db.QueryRow(`SELECT COUNT(*) FROM jobs WHERE singer=? AND status IN ('pending','downloading','ready')`, singer).Scan(&inQueue)
	if inQueue >= maxPerSinger {
		http.Error(w, fmt.Sprintf("max %d songs queued per singer", maxPerSinger), http.StatusTooManyRequests)
		return
	}

	// Dedup warning: same yt_id already in active queue from any singer
	if ytID != "" {
		var dupTitle, dupSinger string
		if db.QueryRow(`SELECT title, singer FROM jobs WHERE yt_id=? AND status IN ('pending','downloading','ready') LIMIT 1`, ytID).
			Scan(&dupTitle, &dupSinger) == nil {
			writeJSON(w, map[string]any{"status": "duplicate_warning", "queued_by": dupSinger, "title": dupTitle})
			return
		}
	}

	// Upsert singer profile
	db.Exec(`INSERT OR IGNORE INTO singers(name) VALUES(?)`, singer)
	db.Exec(`UPDATE singers SET last_seen=CURRENT_TIMESTAMP WHERE name=?`, singer)

	var keyOffset int
	db.QueryRow(`SELECT key_offset FROM singers WHERE name=?`, singer).Scan(&keyOffset)

	// Cache hit: file already downloaded
	if ytID != "" {
		var cached string
		if db.QueryRow(`SELECT filename FROM jobs WHERE yt_id=? AND status='played' AND filename!='' LIMIT 1`, ytID).Scan(&cached) == nil {
			if _, err := os.Stat(cached); err == nil {
				db.Exec(`INSERT INTO jobs(yt_id,url,status,title,singer,filename,thumbnail,key_offset,duration) VALUES(?,?,'ready',?,?,?,?,?,?)`,
					ytID, url, title, singer, cached, thumbnail, keyOffset, duration)
				writeJSON(w, map[string]string{"status": "cached"})
				return
			}
		}
	}

	db.Exec(`INSERT INTO jobs(yt_id,url,status,title,singer,thumbnail,key_offset,duration) VALUES(?,?,'pending',?,?,?,?,?)`,
		ytID, url, title, singer, thumbnail, keyOffset, duration)
	writeJSON(w, map[string]string{"status": "queued"})
}

func handleSkip(w http.ResponseWriter, r *http.Request) {
	playerMu.Lock()
	defer playerMu.Unlock()
	killCmd(playerCmd)
	select {
	case skipCh <- struct{}{}:
	default:
	}
	writeJSON(w, map[string]string{"status": "skipped"})
}

func handleDelete(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", http.StatusBadRequest)
		return
	}
	id := strings.TrimSpace(r.FormValue("id"))
	if id == "" {
		http.Error(w, "id required", http.StatusBadRequest)
		return
	}
	result, err := db.Exec(`UPDATE jobs SET status='played' WHERE id=? AND status NOT IN ('playing')`, id)
	if err != nil {
		http.Error(w, "delete failed", http.StatusInternalServerError)
		return
	}
	affected, _ := result.RowsAffected()
	if affected == 0 {
		http.Error(w, "not found or currently playing", http.StatusConflict)
		return
	}
	writeJSON(w, map[string]any{"status": "deleted", "id": id})
}

func handleDeleteHistory(w http.ResponseWriter, r *http.Request) {
	var body struct {
		YtID   string `json:"yt_id"`
		Singer string `json:"singer"`
		Scope  string `json:"scope"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	body.YtID = strings.TrimSpace(body.YtID)
	body.Singer = strings.TrimSpace(body.Singer)
	if body.YtID == "" {
		http.Error(w, "yt_id required", http.StatusBadRequest)
		return
	}

	var (
		result sql.Result
		err    error
	)
	if body.Scope == "singer" && body.Singer != "" {
		result, err = db.Exec(`DELETE FROM singer_history WHERE yt_id=? AND singer=?`, body.YtID, body.Singer)
		db.Exec(`DELETE FROM singer_favorites WHERE yt_id=? AND singer=?`, body.YtID, body.Singer)
	} else {
		result, err = db.Exec(`DELETE FROM singer_history WHERE yt_id=?`, body.YtID)
		db.Exec(`DELETE FROM singer_favorites WHERE yt_id=?`, body.YtID)
	}
	if err != nil {
		http.Error(w, "history delete failed", http.StatusInternalServerError)
		return
	}
	affected, _ := result.RowsAffected()
	writeJSON(w, map[string]any{"status": "deleted", "yt_id": body.YtID, "deleted": affected})
}

func handleQueueKey(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var locked int
	if err := db.QueryRow(`SELECT locked FROM jobs WHERE id=?`, id).Scan(&locked); err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if locked == 1 {
		http.Error(w, "song is locked (within 10s of playing)", http.StatusConflict)
		return
	}
	var body struct {
		KeyOffset int `json:"key_offset"`
	}
	json.NewDecoder(r.Body).Decode(&body)
	if body.KeyOffset < -6 || body.KeyOffset > 6 {
		http.Error(w, "key_offset must be -6 to +6", http.StatusBadRequest)
		return
	}
	db.Exec(`UPDATE jobs SET key_offset=? WHERE id=?`, body.KeyOffset, id)
	writeJSON(w, map[string]string{"status": "updated"})
}

// ── Search ───────────────────────────────────────────────────────────────────

var invidiousInstances = []string{
	"https://invidious.io.lol",
	"https://invidious.privacyredirect.com",
	"https://inv.nadeko.net",
	"https://invidious.nerdvpn.de",
	"https://yt.cdaut.de",
	"https://invidious.fdn.fr",
	"https://invidious.flokinet.to",
	"https://invidious.tiekoetter.com",
	"https://invidious.slipfox.xyz",
}

func handleSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		writeJSON(w, []SearchResult{})
		return
	}
	query := q + " karaoke"
	results := searchInvidious(query)
	if len(results) == 0 {
		results = searchYtdlp(query)
	}
	writeJSON(w, results)
}

func searchInvidious(q string) []SearchResult {
	client := &http.Client{Timeout: 4 * time.Second}
	for _, inst := range invidiousInstances {
		reqURL := inst + "/api/v1/search?q=" + url.QueryEscape(q) + "&type=video&fields=videoId,title,author,lengthSeconds,videoThumbnails"
		resp, err := client.Get(reqURL)
		if err != nil {
			continue
		}
		var items []struct {
			VideoID    string `json:"videoId"`
			Title      string `json:"title"`
			Author     string `json:"author"`
			Length     int    `json:"lengthSeconds"`
			Thumbnails []struct {
				URL string `json:"url"`
			} `json:"videoThumbnails"`
		}
		err = json.NewDecoder(resp.Body).Decode(&items)
		resp.Body.Close()
		if err != nil || len(items) == 0 {
			continue
		}
		results := make([]SearchResult, 0, 5)
		for i, item := range items {
			if i >= 5 {
				break
			}
			thumb := ""
			if len(item.Thumbnails) > 0 {
				thumb = item.Thumbnails[0].URL
			}
			results = append(results, SearchResult{
				ID: item.VideoID, Title: item.Title, Uploader: item.Author,
				Duration: formatDuration(item.Length),
				URL:      "https://www.youtube.com/watch?v=" + item.VideoID,
				Thumb:    thumb,
			})
		}
		return results
	}
	return nil
}

func searchYtdlp(q string) []SearchResult {
	out, err := exec.Command("yt-dlp",
		"--print", "%(id)s<|>%(title)s<|>%(uploader)s<|>%(duration_string)s<|>%(thumbnail)s",
		"--flat-playlist", "--no-warnings", "--js-runtimes", "node",
		"ytsearch5:"+q,
	).Output()
	if err != nil {
		return nil
	}
	var results []SearchResult
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		parts := strings.SplitN(line, "<|>", 5)
		if len(parts) < 4 {
			continue
		}
		thumb := ""
		if len(parts) == 5 {
			thumb = parts[4]
		}
		results = append(results, SearchResult{
			ID: parts[0], Title: parts[1], Uploader: parts[2], Duration: parts[3],
			URL:   "https://www.youtube.com/watch?v=" + parts[0],
			Thumb: thumb,
		})
	}
	return results
}

// ── Singer Profile Handlers ───────────────────────────────────────────────────

func handleGetSinger(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")

	s := Singer{Name: name, KeyOffset: 0, Volume: 80}
	db.QueryRow(`SELECT key_offset, volume, last_seen FROM singers WHERE name=?`, name).
		Scan(&s.KeyOffset, &s.Volume, &s.LastSeen)

	type HistItem struct {
		YtID      string `json:"yt_id"`
		Title     string `json:"title"`
		Thumbnail string `json:"thumbnail"`
		KeyOffset int    `json:"key_offset"`
		PlayCount int    `json:"play_count"`
		PlayedAt  string `json:"played_at"`
	}
	type FavItem struct {
		YtID      string `json:"yt_id"`
		Title     string `json:"title"`
		Thumbnail string `json:"thumbnail"`
	}

	history := []HistItem{}
	rows, err := db.Query(`SELECT yt_id,title,thumbnail,key_offset,play_count,played_at FROM singer_history WHERE singer=? ORDER BY played_at DESC LIMIT 100`, name)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var h HistItem
			if err := rows.Scan(&h.YtID, &h.Title, &h.Thumbnail, &h.KeyOffset, &h.PlayCount, &h.PlayedAt); err == nil {
				history = append(history, h)
			}
		}
	} else {
		logWarnf("[singer] history query failed for %q: %v", name, err)
	}

	favorites := []FavItem{}
	frows, err := db.Query(`SELECT yt_id,title,thumbnail FROM singer_favorites WHERE singer=? ORDER BY added_at DESC`, name)
	if err == nil {
		defer frows.Close()
		for frows.Next() {
			var f FavItem
			if err := frows.Scan(&f.YtID, &f.Title, &f.Thumbnail); err == nil {
				favorites = append(favorites, f)
			}
		}
	} else {
		logWarnf("[singer] favorites query failed for %q: %v", name, err)
	}

	writeJSON(w, map[string]any{"singer": s, "history": history, "favorites": favorites})
}

func handleUpdateSinger(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	var body struct {
		KeyOffset *int `json:"key_offset"`
		Volume    *int `json:"volume"`
	}
	json.NewDecoder(r.Body).Decode(&body)

	db.Exec(`INSERT OR IGNORE INTO singers(name) VALUES(?)`, name)
	if body.KeyOffset != nil {
		if *body.KeyOffset < -6 || *body.KeyOffset > 6 {
			http.Error(w, "key_offset must be -6 to +6", http.StatusBadRequest)
			return
		}
		db.Exec(`UPDATE singers SET key_offset=? WHERE name=?`, *body.KeyOffset, name)
	}
	if body.Volume != nil {
		if *body.Volume < 0 || *body.Volume > 100 {
			http.Error(w, "volume must be 0-100", http.StatusBadRequest)
			return
		}
		db.Exec(`UPDATE singers SET volume=? WHERE name=?`, *body.Volume, name)
		proxyVolume(*body.Volume)
	}
	writeJSON(w, map[string]string{"status": "updated"})
}

func handleToggleFavorite(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	var body struct {
		YtID      string `json:"yt_id"`
		Title     string `json:"title"`
		Thumbnail string `json:"thumbnail"`
	}
	json.NewDecoder(r.Body).Decode(&body)

	var exists int
	db.QueryRow(`SELECT COUNT(*) FROM singer_favorites WHERE singer=? AND yt_id=?`, name, body.YtID).Scan(&exists)
	if exists > 0 {
		db.Exec(`DELETE FROM singer_favorites WHERE singer=? AND yt_id=?`, name, body.YtID)
		writeJSON(w, map[string]string{"status": "removed"})
	} else {
		db.Exec(`INSERT INTO singer_favorites(singer,yt_id,title,thumbnail) VALUES(?,?,?,?)`,
			name, body.YtID, body.Title, body.Thumbnail)
		writeJSON(w, map[string]string{"status": "added"})
	}
}

// ── Volume / Sync / Storage Handlers ─────────────────────────────────────────

func handleGetVolume(w http.ResponseWriter, r *http.Request) {
	resp, err := http.Get(soundSuper + "/audio/volume")
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	var raw any
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	switch v := raw.(type) {
	case float64:
		writeJSON(w, map[string]int{"volume": int(v), "percent": int(v)})
	case map[string]any:
		writeJSON(w, v)
	default:
		writeJSON(w, map[string]any{"volume": raw})
	}
}

func handleSetVolume(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Volume int `json:"volume"`
	}
	json.NewDecoder(r.Body).Decode(&body)
	proxyVolume(body.Volume)
	writeJSON(w, map[string]any{"status": "ok", "volume": body.Volume, "percent": body.Volume})
}

func handleGetMicGain(w http.ResponseWriter, r *http.Request) {
	_, err := micSource()
	writeJSON(w, map[string]any{"gain": micGain(), "available": err == nil})
}

func handleSetMicGain(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Gain int `json:"gain"`
	}
	json.NewDecoder(r.Body).Decode(&body)
	if body.Gain < 0 || body.Gain > 100 {
		http.Error(w, "gain must be 0-100", http.StatusBadRequest)
		return
	}
	configSet("mic_gain", strconv.Itoa(body.Gain))
	if err := applyMicGain(body.Gain); err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, map[string]any{"status": "ok", "gain": body.Gain})
}

func handleGetSync(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]int{"sync_offset_ms": syncOffset()})
}

func handleSetSync(w http.ResponseWriter, r *http.Request) {
	var body struct {
		OffsetMs int `json:"offset_ms"`
	}
	json.NewDecoder(r.Body).Decode(&body)
	if body.OffsetMs < -2000 || body.OffsetMs > 2000 {
		http.Error(w, "offset_ms must be -2000 to +2000", http.StatusBadRequest)
		return
	}
	rounded := (body.OffsetMs / 200) * 200
	configSet("sync_offset_ms", strconv.Itoa(rounded))
	select {
	case syncChangeCh <- struct{}{}:
	default:
	}
	writeJSON(w, map[string]any{"status": "ok", "sync_offset_ms": rounded})
}

func handleStorageStats(w http.ResponseWriter, r *http.Request) {
	used := dirSize(downloadPath)
	quota := quotaBytes()
	var count int
	db.QueryRow(`SELECT COUNT(DISTINCT filename) FROM jobs WHERE filename!='' AND status='played'`).Scan(&count)
	writeJSON(w, map[string]any{
		"used_bytes":  used,
		"quota_bytes": quota,
		"free_bytes":  quota - used,
		"song_count":  count,
	})
}

func handleSetQuota(w http.ResponseWriter, r *http.Request) {
	var body struct {
		QuotaBytes int64 `json:"quota_bytes"`
	}
	json.NewDecoder(r.Body).Decode(&body)
	if body.QuotaBytes < 1<<30 {
		http.Error(w, "minimum quota is 1 GB", http.StatusBadRequest)
		return
	}
	configSet("quota_bytes", strconv.FormatInt(body.QuotaBytes, 10))
	writeJSON(w, map[string]string{"status": "updated"})
}

func handleShutdown(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{"status": "shutting down"})
	go func() { time.Sleep(300 * time.Millisecond); os.Exit(0) }()
}

// ── Workers ───────────────────────────────────────────────────────────────────

var progressRe = regexp.MustCompile(`\s*(\d{1,3}(?:\.\d+)?)%`)

func downloadWorker() {
	for {
		var id int64
		var url, ytID, title, thumbnail, duration string
		err := db.QueryRow(
			`SELECT id,url,yt_id,title,thumbnail,duration FROM jobs WHERE status='pending' ORDER BY id LIMIT 1`,
		).Scan(&id, &url, &ytID, &title, &thumbnail, &duration)
		if err != nil {
			time.Sleep(2 * time.Second)
			continue
		}
		db.Exec(`UPDATE jobs SET status='downloading' WHERE id=?`, id)

		if err := ensureSpace(600 << 20); err != nil {
			logWarnf("[storage] pre-download eviction failed: %v", err)
			db.Exec(`UPDATE jobs SET status='failed' WHERE id=?`, id)
			time.Sleep(5 * time.Second)
			continue
		}

		outTmpl := filepath.Join(downloadPath, "%(title)s.%(ext)s")
		args := []string{
			"--newline", "--no-playlist",
			"-f", fmt.Sprintf("best[height<=%s]/bestvideo[height<=%s]+bestaudio/best", quality, quality),
			"--js-runtimes", "node",
			"-o", outTmpl,
			"--print", "after_move:filepath",
			url,
		}
		if _, err := os.Stat("cookies.txt"); err == nil {
			args = append(args, "--cookies", "cookies.txt")
		}

		cmd := exec.Command("yt-dlp", args...)
		stdout, _ := cmd.StdoutPipe()
		stderr, _ := cmd.StderrPipe()
		go io.Copy(io.Discard, stderr)
		cmd.Start()

		var finalPath string
		buf := make([]byte, 512)
		for {
			n, err := stdout.Read(buf)
			if n > 0 {
				line := strings.TrimSpace(string(buf[:n]))
				if m := progressRe.FindStringSubmatch(line); m != nil {
					downloadProgress.Store(id, m[1]+"%")
					db.Exec(`UPDATE jobs SET progress=? WHERE id=?`, m[1]+"%", id)
				} else if strings.HasPrefix(line, "/") {
					finalPath = line
				} else if strings.Contains(line, "Finalizing") {
					downloadProgress.Store(id, "Finalizing")
				}
			}
			if err != nil {
				break
			}
		}
		cmd.Wait()
		downloadProgress.Delete(id)

		if finalPath != "" {
			db.Exec(`UPDATE jobs SET status='ready', filename=? WHERE id=?`, finalPath, id)
			logInfof("[download] done: %s", finalPath)
		} else {
			db.Exec(`UPDATE jobs SET status='failed' WHERE id=?`, id)
			logErrorf("[download] failed: %s", url)
		}
	}
}

func playerWorker() {
	var lastSinger string
	for {
		var id int64
		var filename, singer, title, ytID, thumbnail string
		var keyOffset int
		err := db.QueryRow(
			`SELECT id,filename,singer,title,yt_id,thumbnail,key_offset FROM jobs WHERE status='ready' ORDER BY id LIMIT 1`,
		).Scan(&id, &filename, &singer, &title, &ytID, &thumbnail, &keyOffset)
		if err != nil {
			stateMu.Lock()
			playerState = "idle"
			stateMu.Unlock()
			lastSinger = ""
			time.Sleep(2 * time.Second)
			continue
		}

		// Between-songs transition
		if lastSinger != "" {
			if singer == lastSinger {
				time.Sleep(1 * time.Second)
			} else {
				stateMu.Lock()
				playerState = "up_next"
				upNextUntil = time.Now().Add(10 * time.Second)
				upNextSinger = singer
				upNextTitle = title
				stateMu.Unlock()
				time.Sleep(10 * time.Second)
			}
		}

		// Lock this job — no more key changes
		db.Exec(`UPDATE jobs SET status='playing', locked=1 WHERE id=?`, id)

		stateMu.Lock()
		playerState = "playing"
		songStartTime = time.Now()
		stateMu.Unlock()

		currentFileMu.Lock()
		currentFile = filename
		currentFileMu.Unlock()

		logInfof("[player] %s — %s (key %+d)", singer, title, keyOffset)
		play(filename, keyOffset)

		currentFileMu.Lock()
		currentFile = ""
		currentFileMu.Unlock()

		// Record history
		db.Exec(`
			INSERT INTO singer_history(singer,yt_id,title,thumbnail,key_offset,play_count,played_at)
			VALUES(?,?,?,?,?,1,CURRENT_TIMESTAMP)
			ON CONFLICT(singer,yt_id) DO UPDATE SET play_count=play_count+1, played_at=CURRENT_TIMESTAMP`,
			singer, ytID, title, thumbnail, keyOffset)

		db.Exec(`UPDATE jobs SET status='played' WHERE id=?`, id)
		lastSinger = singer
	}
}

func play(filename string, semitones int) {
	pitch := math.Pow(2, float64(semitones)/12)

	duration := probeDuration(filename)
	if duration <= 0 {
		duration = 4 * time.Minute
	}
	end := time.NewTimer(duration)
	defer end.Stop()

	// Drain stale mode-change signal from a previous song.
	select {
	case <-modeChangeCh:
	default:
	}
	select {
	case <-skipCh:
	default:
	}
	select {
	case <-syncChangeCh:
	default:
	}

	startSpeakers := func() {
		playerMu.Lock()
		defer playerMu.Unlock()
		if playerCmd != nil {
			return
		}
		stateMu.Lock()
		startMs := time.Since(songStartTime).Milliseconds()
		stateMu.Unlock()
		cmd := makePipeWireCmd(filename, semitones, pitch, startMs, int64(syncOffset()))
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		if err := cmd.Start(); err != nil {
			logErrorf("[player] speakers start failed: %v", err)
			return
		}
		playerCmd = cmd
		logInfof("[player] speakers on")
		go func() {
			err := cmd.Wait()
			msg := strings.TrimSpace(stderr.String())
			if err != nil {
				logWarnf("[player] speakers exited: %v stderr=%q", err, msg)
				return
			}
			if msg != "" {
				logDebugf("[player] speakers stopped: %s", msg)
			}
		}()
	}

	stopSpeakers := func() {
		playerMu.Lock()
		defer playerMu.Unlock()
		if playerCmd == nil {
			return
		}
		killCmd(playerCmd)
		playerCmd = nil
		logInfof("[player] speakers off")
	}

	stopLocalAudio := func() {
		stopSpeakers()
		if err := disableMicLoopback(); err != nil {
			logWarnf("[mic] loopback disable failed: %v", err)
		}
		notifyPlayback(false)
	}

	startLocalAudio := func() {
		notifyPlayback(true)
		time.Sleep(800 * time.Millisecond)
		if err := ensureMicLoopback(); err != nil {
			logWarnf("[mic] loopback unavailable: %v", err)
		}
		startSpeakers()
	}

	audioModeMu.RLock()
	if audioMode == "local" {
		startLocalAudio()
	}
	audioModeMu.RUnlock()
	defer stopLocalAudio()

	for {
		select {
		case <-end.C:
			return
		case <-skipCh:
			return
		case <-modeChangeCh:
			audioModeMu.RLock()
			mode := audioMode
			audioModeMu.RUnlock()
			if mode == "local" {
				startLocalAudio()
			} else {
				stopLocalAudio()
			}
		case <-syncChangeCh:
			audioModeMu.RLock()
			mode := audioMode
			audioModeMu.RUnlock()
			if mode == "local" {
				stopLocalAudio()
				startLocalAudio()
			}
		}
	}
}

func makePipeWireCmd(filename string, semitones int, pitch float64, startMs, syncMs int64) *exec.Cmd {
	audioDelayMs := int64(0)
	if syncMs < 0 {
		audioDelayMs = -syncMs
	}
	seekMs := startMs - audioDelayMs
	if seekMs < 0 {
		seekMs = 0
	}
	initialDelayMs := audioDelayMs - startMs
	if initialDelayMs < 0 {
		initialDelayMs = 0
	}

	args := []string{"-hide_banner", "-loglevel", "warning", "-nostdin"}
	if seekMs > 0 {
		args = append(args, "-ss", fmt.Sprintf("%.3f", float64(seekMs)/1000))
	}
	args = append(args, "-i", filename, "-vn")
	filters := []string{}
	if semitones != 0 {
		filters = append(filters, fmt.Sprintf("rubberband=pitch=%f", pitch))
	}
	if initialDelayMs > 0 {
		filters = append(filters, fmt.Sprintf("adelay=%d:all=1", initialDelayMs))
	}
	if len(filters) > 0 {
		args = append(args, "-af", strings.Join(filters, ","))
	}
	args = append(args,
		"-f", "pulse",
		"-device", "balena-sound.input",
		"-name", "karaoke",
		"-stream_name", "karaoke",
		"karaoke",
	)
	cmd := exec.Command("ffmpeg", args...)
	cmd.Env = os.Environ()
	return cmd
}

func notifyPlayback(playing bool) {
	endpoint := "/internal/stop"
	if playing {
		endpoint = "/internal/play"
	}
	req, err := http.NewRequest(http.MethodPost, soundSuper+endpoint, nil)
	if err != nil {
		logDebugf("[player] playback notify request failed: %v", err)
		return
	}
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		logWarnf("[player] playback notify %s failed: %v", endpoint, err)
		return
	}
	resp.Body.Close()
	if resp.StatusCode >= 400 {
		logWarnf("[player] playback notify %s returned %s", endpoint, resp.Status)
	}
}

func syncOffset() int {
	offset, _ := strconv.Atoi(configGet("sync_offset_ms", envOr("KARAOKE_SYNC_OFFSET_MS", "0")))
	if offset < -2000 {
		offset = -2000
	}
	if offset > 2000 {
		offset = 2000
	}
	return (offset / 200) * 200
}

func micGain() int {
	gain, _ := strconv.Atoi(configGet("mic_gain", envOr("KARAOKE_MIC_GAIN", envOr("AUDIO_MIC_INPUT_VOLUME", "35"))))
	if gain < 0 {
		return 0
	}
	if gain > 100 {
		return 100
	}
	return gain
}

func pactl(args ...string) ([]byte, error) {
	cmd := exec.Command("pactl", args...)
	cmd.Env = os.Environ()
	return cmd.CombinedOutput()
}

func micSource() (string, error) {
	out, err := pactl("list", "short", "sources")
	if err != nil {
		return "", fmt.Errorf("pactl sources failed: %s", strings.TrimSpace(string(out)))
	}
	var fallback string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) < 2 {
			continue
		}
		name := fields[1]
		if strings.Contains(name, ".monitor") || strings.Contains(name, "balena-sound") || strings.Contains(name, "snapcast") {
			continue
		}
		if name == "mic_filtered" {
			return name, nil
		}
		if fallback == "" {
			fallback = name
		}
	}
	if fallback == "" {
		return "", fmt.Errorf("no microphone source found")
	}
	return fallback, nil
}

func applyMicGain(gain int) error {
	source, err := micSource()
	if err != nil {
		return err
	}
	out, err := pactl("set-source-volume", source, fmt.Sprintf("%d%%", gain))
	if err != nil {
		return fmt.Errorf("set mic gain failed: %s", strings.TrimSpace(string(out)))
	}
	return nil
}

func ensureMicLoopback() error {
	micLoopbackMu.Lock()
	defer micLoopbackMu.Unlock()

	if err := unloadKaraokeMicLoopbacksLocked(); err != nil {
		logDebugf("[mic] stale loopback cleanup failed: %v", err)
	}
	source, err := micSource()
	if err != nil {
		return err
	}
	gain := micGain()
	if err := applyMicGain(gain); err != nil {
		return err
	}
	out, err := pactl(
		"load-module", "module-loopback",
		"source="+source,
		"sink=balena-sound.input",
		"latency_msec=50",
		"remix=true",
		"sink_input_properties=media.name="+karaokeMicLoopbackName,
		"source_output_properties=media.name="+karaokeMicLoopbackName,
	)
	if err != nil {
		return fmt.Errorf("load mic loopback failed: %s", strings.TrimSpace(string(out)))
	}
	logInfof("[mic] loopback on (%s @ %d%%)", source, gain)
	return nil
}

func disableMicLoopback() error {
	micLoopbackMu.Lock()
	defer micLoopbackMu.Unlock()
	return unloadKaraokeMicLoopbacksLocked()
}

func unloadKaraokeMicLoopbacksLocked() error {
	out, err := pactl("list", "modules", "short")
	if err != nil {
		return fmt.Errorf("pactl modules failed: %s", strings.TrimSpace(string(out)))
	}
	var firstErr error
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) < 3 || fields[1] != "module-loopback" {
			continue
		}
		args := strings.Join(fields[2:], " ")
		if !strings.Contains(args, "sink=balena-sound.input") || strings.Contains(args, ".monitor") {
			continue
		}
		isKaraokeLoopback := strings.Contains(args, karaokeMicLoopbackName)
		isLegacyKaraokeLoopback := strings.Contains(args, "latency_msec=50") && strings.Contains(args, "remix=true")
		if !isKaraokeLoopback && !isLegacyKaraokeLoopback {
			continue
		}
		unloadOut, unloadErr := pactl("unload-module", fields[0])
		if unloadErr != nil && firstErr == nil {
			firstErr = fmt.Errorf("unload mic loopback %s failed: %s", fields[0], strings.TrimSpace(string(unloadOut)))
		}
	}
	return firstErr
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func handleCurrentStream(w http.ResponseWriter, r *http.Request) {
	currentFileMu.RLock()
	f := currentFile
	currentFileMu.RUnlock()
	if f == "" {
		http.NotFound(w, r)
		return
	}
	http.ServeFile(w, r, f)
}

func probeDuration(filename string) time.Duration {
	out, err := exec.Command(
		"ffprobe",
		"-v", "error",
		"-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1",
		filename,
	).Output()
	if err != nil {
		logDebugf("[player] ffprobe duration failed: %v", err)
		return 0
	}
	seconds, err := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	if err != nil || seconds <= 0 {
		return 0
	}
	return time.Duration(seconds * float64(time.Second))
}

func killCmd(cmd *exec.Cmd) {
	if cmd != nil && cmd.Process != nil {
		cmd.Process.Kill()
	}
}

func handleGetAudioMode(w http.ResponseWriter, _ *http.Request) {
	audioModeMu.RLock()
	mode := audioMode
	audioModeMu.RUnlock()
	writeJSON(w, map[string]string{"mode": mode})
}

func handleSetAudioMode(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Mode string `json:"mode"`
	}
	json.NewDecoder(r.Body).Decode(&body)
	if body.Mode != "local" && body.Mode != "stream" {
		http.Error(w, "mode must be 'local' or 'stream'", http.StatusBadRequest)
		return
	}
	audioModeMu.Lock()
	audioMode = body.Mode
	audioModeMu.Unlock()
	if body.Mode == "stream" {
		if err := disableMicLoopback(); err != nil {
			logWarnf("[mic] loopback disable failed: %v", err)
		}
	}
	// Signal play() to toggle speaker routing (non-blocking send).
	select {
	case modeChangeCh <- struct{}{}:
	default:
	}
	writeJSON(w, map[string]string{"mode": body.Mode})
}

func handleQR(w http.ResponseWriter, r *http.Request) {
	host := r.Host
	if host == "" {
		host = "localhost:8080"
	}
	joinURL := "http://" + host + "/"
	out, err := exec.Command("qrencode", "-t", "PNG", "-o", "-", "-s", "5", joinURL).Output()
	if err != nil {
		http.Error(w, "qrencode: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	w.Write(out)
}

func proxyVolume(percent int) {
	body := strings.NewReader(fmt.Sprintf(`{"volume":%d}`, percent))
	resp, err := http.Post(soundSuper+"/audio/volume", "application/json", body)
	if err != nil {
		logWarnf("[volume] proxy error: %v", err)
		return
	}
	resp.Body.Close()
}

func lockUpcoming() {
	// Lock the first ready job — it's up next
	db.Exec(`UPDATE jobs SET locked=1 WHERE id=(SELECT id FROM jobs WHERE status='ready' ORDER BY id LIMIT 1)`)
}

func queryByStatus(status string, limit int) []*Job {
	return queryMultiStatusLimited([]string{status}, limit)
}

func queryMultiStatus(statuses []string) []*Job {
	return queryMultiStatusLimited(statuses, 0)
}

func queryMultiStatusLimited(statuses []string, limit int) []*Job {
	ph := make([]string, len(statuses))
	args := make([]any, len(statuses))
	for i, s := range statuses {
		ph[i] = "?"
		args[i] = s
	}
	q := fmt.Sprintf(
		`SELECT id,yt_id,status,title,singer,filename,progress,key_offset,locked,thumbnail,duration
		 FROM jobs WHERE status IN (%s) ORDER BY id`, strings.Join(ph, ","))
	if limit > 0 {
		q += " LIMIT ?"
		args = append(args, limit)
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var jobs []*Job
	for rows.Next() {
		j := &Job{}
		var lockedInt int
		rows.Scan(&j.ID, &j.YtID, &j.Status, &j.Title, &j.Singer, &j.Filename,
			&j.Progress, &j.KeyOffset, &lockedInt, &j.Thumbnail, &j.Duration)
		j.Locked = lockedInt == 1
		if p, ok := downloadProgress.Load(j.ID); ok {
			j.Progress = p.(string)
		}
		jobs = append(jobs, j)
	}
	return jobs
}

func queryHistory(singer, filter string, limit int) []*Job {
	var (
		rows *sql.Rows
		err  error
	)
	switch filter {
	case "me":
		rows, err = db.Query(
			`SELECT yt_id,title,thumbnail,key_offset FROM singer_history WHERE singer=? ORDER BY played_at DESC LIMIT ?`,
			singer, limit)
	case "most":
		rows, err = db.Query(
			`WITH ranked AS (
				SELECT yt_id,title,thumbnail,key_offset,played_at,
				       SUM(play_count) OVER (PARTITION BY yt_id) AS total_plays,
				       ROW_NUMBER() OVER (PARTITION BY yt_id ORDER BY played_at DESC) AS rn
				  FROM singer_history
			)
			SELECT yt_id,title,thumbnail,key_offset
			  FROM ranked
			 WHERE rn=1
			 ORDER BY total_plays DESC, played_at DESC
			 LIMIT ?`,
			limit)
	default:
		rows, err = db.Query(
			`WITH ranked AS (
				SELECT yt_id,title,thumbnail,key_offset,played_at,
				       ROW_NUMBER() OVER (PARTITION BY yt_id ORDER BY played_at DESC) AS rn
				  FROM singer_history
			)
			SELECT yt_id,title,thumbnail,key_offset
			  FROM ranked
			 WHERE rn=1
			 ORDER BY played_at DESC
			 LIMIT ?`,
			limit)
	}
	jobs := []*Job{}
	if err != nil {
		logWarnf("[history] query failed for filter=%q singer=%q: %v", filter, singer, err)
		return jobs
	}
	defer rows.Close()
	for rows.Next() {
		j := &Job{Status: "played"}
		rows.Scan(&j.YtID, &j.Title, &j.Thumbnail, &j.KeyOffset)
		jobs = append(jobs, j)
	}
	return jobs
}

func quotaBytes() int64 {
	val := configGet("quota_bytes", "")
	if val == "" {
		var stat syscall.Statfs_t
		if err := syscall.Statfs(downloadPath, &stat); err == nil {
			quota := int64(stat.Bavail) * int64(stat.Bsize) / 2
			configSet("quota_bytes", strconv.FormatInt(quota, 10))
			return quota
		}
		return 10 << 30
	}
	n, _ := strconv.ParseInt(val, 10, 64)
	return n
}

func dirSize(path string) int64 {
	var total int64
	filepath.Walk(path, func(_ string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return total
}

func ensureSpace(needed int64) error {
	quota := quotaBytes()
	headroom := quota / 10
	used := dirSize(downloadPath)
	if used+needed <= quota-headroom {
		return nil
	}
	return evictLRU(needed + headroom)
}

func evictLRU(needed int64) error {
	// Build protected set (currently playing + next in queue)
	protected := map[string]bool{}
	rows, _ := db.Query(`SELECT COALESCE(filename,'') FROM jobs WHERE status IN ('playing','ready') ORDER BY id LIMIT 2`)
	for rows.Next() {
		var f string
		rows.Scan(&f)
		if f != "" {
			protected[f] = true
		}
	}
	rows.Close()

	// Evict oldest-played files first
	crows, err := db.Query(
		`SELECT DISTINCT filename FROM jobs WHERE status='played' AND filename!=''
		 ORDER BY id ASC`)
	if err != nil {
		return err
	}
	defer crows.Close()

	freed := int64(0)
	for crows.Next() && freed < needed {
		var fname string
		crows.Scan(&fname)
		if protected[fname] {
			continue
		}
		info, err := os.Stat(fname)
		if err != nil {
			continue
		}
		if os.Remove(fname) == nil {
			freed += info.Size()
			logInfof("[storage] evicted %s (%.1f MB)", filepath.Base(fname), float64(info.Size())/(1<<20))
		}
	}
	if freed < needed {
		return fmt.Errorf("freed %.1f MB, needed %.1f MB", float64(freed)/(1<<20), float64(needed)/(1<<20))
	}
	return nil
}

func configGet(key, def string) string {
	var val string
	if err := db.QueryRow(`SELECT value FROM config WHERE key=?`, key).Scan(&val); err != nil {
		return def
	}
	return val
}

func configSet(key, val string) {
	db.Exec(`INSERT OR REPLACE INTO config(key,value) VALUES(?,?)`, key, val)
}

func formatDuration(seconds int) string {
	return fmt.Sprintf("%d:%02d", seconds/60, seconds%60)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envIntOr(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
