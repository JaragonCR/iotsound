# IoTSound Audio Configuration Guide

## Overview

The enhanced audio block now includes automatic device detection, DAC prioritization, and configurable microphone input filtering. This enables seamless multi-room audio streaming with optional microphone support for applications like karaoke.

## Audio Device Detection

### Output Devices (Speakers)

The audio service automatically detects and prioritizes available output devices:

**Priority Order:**
1. **HiFiBerry DAC+** (best quality for hi-fi audio)
2. **USB Audio Devices** (external USB DACs)
3. **HDMI Audio** (TV/monitor speakers)
4. **Built-in 3.5mm Jack** (fallback)

**Configuration:**
- `AUDIO_OUTPUT` - Override auto-detection
  - `AUTO` (default) - Auto-detect using priority order
  - Device name - Force specific device (e.g., `USB`, `HiFiBerry`, `soc_sound`)
  - Device number - Force device by index (e.g., `1`, `2`, `3`)

**Example:**
```
AUDIO_OUTPUT=1          # Force first detected device
AUDIO_OUTPUT=USB        # Force USB device
AUDIO_OUTPUT=AUTO       # Auto-detect (default)
```

### Input Devices (Microphones)

The audio service automatically detects available input sources, with USB microphones preferred over built-in options.

**Priority Order:**
1. **USB Audio Devices** (USB microphones, audio dongles)
2. **Built-in Microphone** (if available)

**Configuration:**
- `AUDIO_INPUT` - Override auto-detection
  - `AUTO` (default) - Auto-detect using priority order
  - Device name - Force specific device (e.g., `USB`, `analog`)
  - Device number - Force device by index (e.g., `1`, `2`)

**Example:**
```
AUDIO_INPUT=AUTO        # Auto-detect (default)
AUDIO_INPUT=1           # Force first detected device
AUDIO_INPUT=USB         # Force USB device
```

**Note:** Detected input device is saved to `/run/pulse/audio-input-device` for use by other applications (like karaoke containers).

## Microphone Audio Filtering

Configurable PipeWire biquad filters for microphone input to improve voice quality and remove unwanted noise.

### Quick Start: Disable All EQ

To quickly disable all microphone filters and use raw input (default):

```
AUDIO_INPUT_EQ_DISABLED = true
AUDIO_MIC_INPUT_VOLUME = 35
```

This ignores all other filter settings and uses the unfiltered USB microphone input. This is the current default while EQ is being refined for production.

### Highpass Filter (Removes Low-Frequency Rumble)

Removes microphone rumble, wind noise, and low-frequency electrical hum.

**Configuration:**
- `AUDIO_INPUT_HIGHPASS` - Cutoff frequency in Hz
  - `120` (default) - Recommended for vocals/karaoke
  - `100` - More aggressive, still preserves voice
  - `0` or empty - Disabled
  - Higher values remove more low frequencies

**Common Settings:**
- `80-100Hz` - For studio/professional vocals
- `120Hz` - For karaoke/consumer microphones (default)
- `150Hz` - Very aggressive, may lose bass tone

### Lowpass Filter (Removes High-Frequency Harshness)

Removes microphone hiss, high-frequency noise, and sibilance.

**Configuration:**
- `AUDIO_INPUT_LOWPASS` - Cutoff frequency in Hz
  - `15000` (default) - Recommended for vocals/karaoke
  - `10000` - More aggressive, adds presence
  - `18000` - Less aggressive, preserves brightness
  - `0` or empty - Disabled
  - `20000` - Full spectrum (no filtering)

**Common Settings:**
- `10000Hz` - Very smooth, warm vocals (aggressive)
- `15000Hz` - Balanced for karaoke (default)
- `18000Hz` - Bright, presence-focused
- `20000Hz` - No lowpass filtering

### Boxy Sound Removal (500Hz Peaking Cut)

Removes the "boxy" or "enclosed" quality that can accumulate in the 500Hz region, making vocals sound trapped or muffled.

**Configuration:**
- `AUDIO_INPUT_BOXY_CUT` - Peaking filter gain in dB at 500Hz
  - `-2` (default) - Subtle cut, removes boxy quality
  - `-3` - More aggressive cut
  - `0` or empty - Disabled (no boxy cut)
  - Positive values (e.g., `+2`) - Boost 500Hz (not recommended for vocals)

**Common Settings:**
- `-2dB` - Default, subtle cut (recommended)
- `-3dB` - More noticeable, for very boxy vocals
- `0` - Disabled, no boxy filtering

### Proximity Effect Removal (250Hz Peaking Cut)

Removes the low-mid boost that occurs when a microphone is held too close to the mouth. This is the natural "proximity effect" where closeness boosts frequencies around 200-300Hz.

**Configuration:**
- `AUDIO_INPUT_PROXIMITY_CUT` - Peaking filter gain in dB at 250Hz
  - `-2` (default) - Subtle cut, reduces proximity boost for close miking
  - `-3` - More aggressive cut for very close miking
  - `0` or empty - Disabled (no proximity cut)
  - Positive values (e.g., `+2`) - Boost 250Hz (not recommended)

**Common Settings:**
- `-2dB` - Default, subtle cut (recommended for close-miking)
- `-3dB` - More aggressive, for very close or sensitive mics
- `0` - Disabled, for normal mic distance (6+ inches away)

**Note:** Proximity effect is a real acoustic phenomenon. If your karaoke performers hold the mic close, use this filter. If they keep proper distance (6+ inches), you can disable it.

### Microphone Input Volume

Control the microphone input level before it reaches loopback or other applications.

**Configuration:**
- `AUDIO_MIC_INPUT_VOLUME` - Input volume in percentage (0-100)
  - `40` (default) - Prevents amplification noise on USB dongles
  - `50` - Standard monitoring level
  - `100` - Full volume (not recommended, adds noise)

## Microphone Loopback (Real-Time Monitoring)

Optional feature that routes microphone input back to speakers for testing and karaoke applications.

**Configuration:**
- `AUDIO_INPUT_LOOPBACK` - Enable/disable mic monitoring
  - `false` (default) - Disabled
  - `true` or `1` - Enabled

When enabled:
- Microphone input is mixed with other audio sources
- Filtered using configured highpass/lowpass settings
- Output at configured volume level
- Useful for karaoke testing and mic verification

**Example:**
```
AUDIO_INPUT_LOOPBACK=true
AUDIO_INPUT_HIGHPASS=120
AUDIO_INPUT_LOWPASS=12000
AUDIO_MIC_INPUT_VOLUME=40
```

## Latency Configuration

Control audio latency for different use cases.

**Configuration:**
- `SOUND_INPUT_LATENCY` - Loopback input latency in milliseconds (default: 200ms)
- `SOUND_OUTPUT_LATENCY` - Loopback output latency in milliseconds (default: 200ms)

**For Karaoke:**
```
SOUND_INPUT_LATENCY=100
SOUND_OUTPUT_LATENCY=100
```

## Balena Fleet Variables

Set these in your Balena fleet configuration to customize audio behavior across all devices:

```
AUDIO_OUTPUT = AUTO
AUDIO_INPUT = AUTO
AUDIO_INPUT_EQ_DISABLED = true
AUDIO_INPUT_HIGHPASS = 130
AUDIO_INPUT_HIGHPASS_Q = 1.0
AUDIO_INPUT_PROXIMITY_CUT = -2
AUDIO_INPUT_BOXY_CUT = -2
AUDIO_INPUT_LOWPASS = 15000
AUDIO_INPUT_LOWPASS_Q = 1.0
AUDIO_MIC_INPUT_VOLUME = 35
AUDIO_INPUT_LOOPBACK = false
SOUND_INPUT_LATENCY = 200
SOUND_OUTPUT_LATENCY = 200
```

**Current defaults:** EQ is disabled (`AUDIO_INPUT_EQ_DISABLED = true`) while being refined. Volume is set to 35% as the sweet spot for USB microphones.

## Device Detection Output

When the audio service starts, it logs available devices:

```
[STEP] Available Hardware Output Sinks:
  1        alsa_output.usb-0d8c_C-Media_USB_Audio_Device-00.analog-stereo
  2        alsa_output.platform-soc_sound.stereo-fallback
  (Set AUDIO_OUTPUT=<name> to force a specific device)

[STEP] Available Hardware Input Sources:
  1        alsa_input.usb-0d8c_C-Media_USB_Audio_Device-00.mono-fallback
  (Set AUDIO_INPUT=<n> to force a specific device)

Microphone filter configuration:
  Highpass: 120Hz (0 = disabled)
  Lowpass: 12000Hz (0 = disabled)
```

You can use these device names or numbers to override auto-detection.

## Karaoke Integration

The karaoke container can automatically detect and use the microphone configured here:

1. **Microphone Detection:**
   - IoTSound audio block detects USB/built-in mic
   - Saves device name to `/run/pulse/audio-input-device`
   - Karaoke container reads this file on startup

2. **Audio Mixing:**
   - Karaoke backing track + filtered mic input
   - All mixed through speakers using PipeWire
   - Independent volume control for mic and backing track

3. **Configuration:**
   ```
   AUDIO_INPUT_LOOPBACK = true        # Enable mic loopback for testing
   AUDIO_INPUT_HIGHPASS = 120         # Remove rumble
   AUDIO_INPUT_LOWPASS = 12000        # Remove harshness
   AUDIO_MIC_INPUT_VOLUME = 40        # Control mic input level
   ```

## Troubleshooting

### No Audio Output
1. Check `AUDIO_OUTPUT` setting - verify device name is correct
2. Check speaker connections and volume levels
3. Verify selected device appears in output sink list

### Microphone Not Detected
1. USB dongle might need to be plugged in before startup
2. Check `AUDIO_INPUT` variable - verify device name is correct
3. Verify microphone appears in input source list

### Audio Quality Issues
- **Too much noise:** Increase `AUDIO_INPUT_HIGHPASS` (e.g., 150Hz)
- **Muffled/dull:** Decrease `AUDIO_INPUT_LOWPASS` (e.g., 10000Hz)
- **Distorted:** Decrease `AUDIO_MIC_INPUT_VOLUME` (e.g., 30%)
- **Too quiet:** Increase `AUDIO_MIC_INPUT_VOLUME` (e.g., 50%)

### Loopback Not Working
1. Ensure `AUDIO_INPUT_LOOPBACK=true`
2. Check that `mic_filtered` source exists: `pactl list sources | grep mic_filtered`
3. Verify loopback module loaded: `pactl list modules | grep loopback`

## Advanced: Manual PipeWire Configuration

For power users, you can create custom PipeWire configurations in `/etc/pipewire/pipewire.conf.d/`.

The automatically generated filter config is stored in:
```
/etc/pipewire/pipewire.conf.d/99-mic-filters.conf
```

Edit this file directly to add additional filters or nodes beyond highpass/lowpass.

## References

- [PipeWire Documentation](https://pipewire.org/)
- [PipeWire Filter Chain Module](https://dv1.pages.freedesktop.org/pipewire/page_module_filter_chain.html)
- [Biquad Filters](https://en.wikipedia.org/wiki/Digital_biquad_filter)