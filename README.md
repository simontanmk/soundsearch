# SoundSearch

**Detect distress sounds. Locate their direction. Guide rescuers.**

SoundSearch is an iOS app that listens for distress sounds — screaming, cries for help — using on-device machine learning, then uses the iPhone's stereo microphones to estimate the direction the sound is coming from. A Find My–style UI with a directional arrow, particle ring, proximity feedback, and haptics guides the user toward the source.

---

## How It Works

### Phase 1 — Detection

The app captures audio from the iPhone's built-in microphones and continuously feeds a 3-second rolling window into a CoreML distress classifier. When the model detects distress sounds with high confidence across 3 consecutive windows, the app transitions to Phase 2.

### Phase 2 — Direction

The same audio stream switches to stereo direction-of-arrival analysis. The app fuses two spatial cues from the left and right microphone channels:

- **ILD (Interaural Level Difference)** — compares volume between channels to estimate angle
- **Time-domain cross-correlation** — measures the time delay between channels for a secondary angle estimate

A directional arrow points toward the sound source, a particle ring glows brighter in the source direction, proximity words ("far" / "near" / "here") indicate confidence, and haptic pulses get faster as you point closer to the source.

---

## Screenshots

| Detection Phase | Direction Phase | Lock Confirmation |
|:-:|:-:|:-:|
| Pulsing cyan ring | Arrow + directional glow | Green checkmark flash |
| *Listening for distress sounds…* | *Tracking sound source* | *Direction locked* |

---

## CoreML Model

### `distress_classifier.mlmodel`

| Property | Value |
|----------|-------|
| **Location** | `SoundSearch/Models/distress_classifier.mlmodel` |
| **Size** | 92 KB |
| **Input** | `mel_spectrogram` — shape `[1, 1, 64, 188]`, Float32 |
| **Output** | `class_probs` — shape `[1, 2]` (index 0 = non-distress, index 1 = distress) |
| **Compute** | CPU + Neural Engine |
| **Input format** | Normalized log-mel spectrogram, values in [0, 1] |
| **Architecture** | SmallAudioCNN — 3-layer CNN (16→32→64 filters) + adaptive avg pool + linear head |

### Test Set Performance

| Metric | Value |
|--------|-------|
| Accuracy | **98.9%** |
| Distress Precision | 98.5% |
| Distress Recall | 98.5% |
| False Negative Rate | 1.5% |
| True Positives / False Positives | 197 / 3 |
| True Negatives / False Negatives | 329 / 3 |
| Test samples | 532 |

### Mel Spectrogram Pipeline

Audio is processed to match the model's training pipeline:

```
48 kHz stereo → mono mix → 16 kHz downsample → STFT (1024-pt, hop 256)
→ 64 mel bins (0–8000 Hz) → log dB → normalize to [0, 1]
```

| Parameter | Value |
|-----------|-------|
| Input sample rate | 48,000 Hz |
| Target sample rate | 16,000 Hz |
| n_fft | 1024 |
| hop_length | 256 |
| n_mels | 64 |
| fmin / fmax | 0 / 8,000 Hz |
| Output shape | 64 × 188 (3 seconds) |
| Normalization | `(dB + 100) / 100`, clamped [0, 1] |

### Classification Logic

- **Silence gate**: Audio RMS < 0.008 → skip inference (prevents false positives from mic self-noise)
- **Threshold**: Distress probability ≥ 0.65
- **Confirmation**: 3 consecutive positive classifications required before transitioning to direction phase
- **Sliding window**: 3-second buffer, slides by 0.5 seconds between classifications

---

## Model Training Pipeline (`mlmodel/`)

The `mlmodel/` directory contains a complete PyTorch training pipeline for the distress classifier. The trained model is exported to CoreML format and bundled into the iOS app.

### Pipeline Structure

```
mlmodel/
├── pipeline/
│   ├── cli.py              # CLI entry point (prepare / train / infer)
│   ├── config.py           # AudioConfig + TrainConfig dataclasses
│   ├── data.py             # Dataset loading, manifest creation, labels
│   ├── model.py            # SmallAudioCNN architecture
│   ├── train.py            # Training loop, validation, test evaluation
│   ├── infer.py            # Single-file inference
│   └── export_coreml.py    # PyTorch → CoreML conversion
├── artifacts/
│   ├── data/
│   │   ├── manifest.csv          # Train/val/test split with labels
│   │   └── manifest_summary.json # Dataset statistics
│   └── model/
│       ├── best_model.pth              # PyTorch checkpoint
│       ├── distress_classifier.mlmodel # Exported CoreML model
│       ├── train_history.json          # Training curves
│       └── test_metrics.json           # Final test performance
├── data/                   # Dataset root (not committed)
├── requirements.txt        # Python dependencies
└── README.md               # Training pipeline docs
```

### Model Architecture — SmallAudioCNN

A lightweight 3-layer CNN designed for on-device inference:

```
Input: [1, 1, 64, 188]  (batch, channel, mel_bins, time_frames)
  │
  ├─ Conv2d(1→16, 3×3) → BatchNorm → ReLU → MaxPool(2×2)
  ├─ Conv2d(16→32, 3×3) → BatchNorm → ReLU → MaxPool(2×2)
  ├─ Conv2d(32→64, 3×3) → BatchNorm → ReLU → AdaptiveAvgPool(1×1)
  │
  ├─ Flatten → Dropout(0.25) → Linear(64→2)
  │
Output: [1, 2]  (non_distress_prob, distress_prob)
```

**Model size**: 92 KB (CoreML). Runs on CPU + Neural Engine.

### Dataset

| Property | Value |
|----------|-------|
| Total samples | 9,299 |
| Reference samples | 5,314 |
| Generated (synthetic) | 5,314 |
| Train / Val / Test | 7,970 / 797 / 532 |

**Distress classes (positive):**
- Asking help
- Screaming
- Crying / sobbing / wail
- Whispering
- Cough

All other audio events are labeled as `non_distress`.

#### Dataset Layout

```
data/DisasterDataset/
  reference/
    <event_name>/*.wav       # Real recordings
  generated/                 # Optional synthetic data
    <event_name>/*.wav
```

### Training

**Requirements**: Python 3.10+

```bash
cd mlmodel

# Install dependencies
pip install -r requirements.txt

# 1. Build manifest (train/val/test split)
python3 -m pipeline.cli prepare \
  --dataset_root data/DisasterDataset \
  --out_dir artifacts/data \
  --generated_ratio 1.0 \
  --val_split 0.15 \
  --test_split 0.10 \
  --seed 42

# 2. Train
python3 -m pipeline.cli train \
  --manifest artifacts/data/manifest.csv \
  --out_dir artifacts/model \
  --epochs 20 \
  --batch_size 32 \
  --lr 1e-3 \
  --distress_weight 2.0 \
  --num_workers 2
```

### Training Configuration

| Parameter | Value |
|-----------|-------|
| Epochs | 20 |
| Batch size | 32 |
| Learning rate | 1e-3 |
| Weight decay | 1e-4 |
| Distress class weight | 2.0× |
| Optimizer | Adam |
| Seed | 42 |
| CUDA | Auto-detected |

### CoreML Export

After training, the PyTorch model is exported to CoreML format via `export_coreml.py` and placed in the iOS project:

```bash
# Export (generates distress_classifier.mlmodel)
python3 -m pipeline.cli export \
  --model artifacts/model/best_model.pth

# Copy to iOS project
cp artifacts/model/distress_classifier.mlmodel \
   ../SoundSearch/Models/distress_classifier.mlmodel
```

### Inference (standalone)

Test on a single WAV file:

```bash
python3 -m pipeline.cli infer \
  --model artifacts/model/best_model.pth \
  --audio path/to/audio.wav
```

---

## Project Structure

```
SoundSearch/
├── SoundSearchApp.swift              # App entry point
├── ContentView.swift                 # Root view (embeds RescueDirectionView)
├── AudioDirectionEngine.swift        # Core audio pipeline (968 lines)
│   ├── Phase 1: Detection            #   Mono mix → DistressClassifier
│   ├── Phase 2: Direction            #   Stereo → StereoTracker / MonoScanTracker
│   ├── StereoTracker                 #   ILD + cross-correlation fusion
│   ├── MonoScanTracker               #   Rotation scan fallback (mono devices)
│   └── Session config                #   Stereo/mono AVAudioSession setup
│
├── Models/
│   ├── DirectionEngine.swift         # Protocol: stream() → AsyncStream<DirectionSample>
│   ├── DirectionSample.swift         # AppPhase enum + sample value type
│   ├── DirectionMath.swift           # Angle normalization utilities
│   ├── DistressClassifier.swift      # CoreML wrapper + rolling buffer + hit logic
│   ├── MelSpectrogram.swift          # Accelerate/vDSP mel spectrogram computation
│   └── distress_classifier.mlmodel   # CoreML distress sound classifier (92 KB)
│
├── ViewModels/
│   └── RescueDirectionViewModel.swift # MVVM bridge (smoothing, lock, haptics)
│
├── Views/
│   └── RescueDirectionView.swift     # Find My–style UI (ring, arrow, proximity)
│
├── Sensors/
│   └── HeadingProvider.swift         # CMDeviceMotion yaw → compass heading
│
├── Haptics/
│   └── HapticsManager.swift          # CoreHaptics directional pulses + lock feedback
│
├── Simulation/
│   ├── SensorDirectionEngine.swift   # Real compass + simulated target (testing)
│   └── SimulatedDirectionEngine.swift # Fully synthetic (Simulator/Preview)
│
├── Assets.xcassets/                  # App icons (light/dark/tinted)
│
└── mlmodel/                          # ML training pipeline (Python)
    ├── pipeline/
    │   ├── cli.py                    # CLI: prepare / train / infer / export
    │   ├── config.py                 # AudioConfig + TrainConfig dataclasses
    │   ├── data.py                   # Dataset loading, manifest, labels
    │   ├── model.py                  # SmallAudioCNN (3-layer CNN)
    │   ├── train.py                  # Training loop + evaluation
    │   ├── infer.py                  # Single-file inference
    │   └── export_coreml.py          # PyTorch → CoreML export
    ├── artifacts/
    │   ├── data/manifest.csv         # Train/val/test split
    │   └── model/
    │       ├── best_model.pth        # PyTorch checkpoint
    │       └── distress_classifier.mlmodel  # Exported CoreML model
    ├── data/                         # Dataset root (not committed)
    └── requirements.txt              # Python dependencies
```

---

## Architecture

```
┌─────────────────────────────────────────────┐
│              RescueDirectionView             │  SwiftUI
│           (particle ring, arrow, haptics)    │
├─────────────────────────────────────────────┤
│           RescueDirectionViewModel           │  MVVM
│        (smoothing, lock detection)           │
├──────────┬──────────────┬───────────────────┤
│  Audio   │   Sensor     │   Simulated       │  Engines
│ Direction│  Direction   │   Direction       │  (protocol)
│  Engine  │   Engine     │    Engine         │
├──────────┴──────────────┴───────────────────┤
│          DirectionEngine protocol            │
│      stream() → AsyncStream<DirectionSample> │
└─────────────────────────────────────────────┘
```

The app selects the best available engine at launch:
1. **AudioDirectionEngine** — real microphone input (requires hardware mic)
2. **SensorDirectionEngine** — real compass + simulated audio (testing on device)
3. **SimulatedDirectionEngine** — fully synthetic (Simulator / SwiftUI Preview)

---

## Stereo Direction Tracking

### ILD (Primary — 85% weight)

Compares RMS power between left and right channels:

```
ILD (dB) = 20 · log₁₀(rmsL / rmsR)
angle = ILD × 18 °/dB
```

### Cross-Correlation (Secondary — 15% weight)

Time-domain cross-correlation with differentiation and RMS normalization:

1. **Differentiate** both channels (high-pass filter removes DC/rumble)
2. **Normalize** each channel by RMS
3. **Cross-correlate** for lags ±12 samples
4. **Parabolic interpolation** for sub-sample TDOA accuracy
5. **Auto bias calibration** — EMA from quiet frames removes hardware inter-channel delay

### Why ILD-Primary?

The iPhone's stereo microphone DSP introduces a fixed inter-channel delay (~5 samples) that dwarfs the physical TDOA from mic spacing (~0–9 samples). This makes cross-correlation unreliable as a primary cue. ILD is unaffected by this delay and tracks direction accurately on iPhone hardware.

---

## Requirements

| Requirement | Details |
|-------------|---------|
| **Platform** | iOS 18.0+ |
| **Device** | iPhone with stereo microphones (iPhone 16 Pro Max tested) |
| **Xcode** | 16.0+ |
| **Swift** | 6.0 |
| **Dependencies** | None (pure Apple frameworks) |

### Frameworks Used

- **AVFoundation** — audio capture, session management
- **Accelerate** — vDSP FFT, mel spectrogram, signal processing
- **CoreML** — distress sound classification
- **CoreLocation** — compass heading (fallback)
- **CoreMotion** — device motion yaw (primary heading)
- **CoreHaptics** — directional haptic feedback
- **SwiftUI** — UI

### Permissions

| Permission | Usage |
|------------|-------|
| Microphone | Audio capture for detection and direction |
| Location (When In Use) | Compass heading for absolute bearing |

---

## Build & Run

```bash
# Clone
git clone https://github.com/simontanmk/SoundSearch.git
cd SoundSearch

# Open in Xcode
open SoundSearch.xcodeproj

# Build & run on a physical device (stereo mics required)
# Simulator works with SimulatedDirectionEngine (no real audio)
```

> **Note**: Stereo direction tracking requires a physical iPhone with stereo microphones. The Simulator will use the `SimulatedDirectionEngine` fallback.

---

## Debug Mode

Enable on-screen diagnostic logs by flipping the toggle in `RescueDirectionViewModel.swift`:

```swift
static let showDebugLog = true  // false for production
```

This displays real-time log lines including:
- Mel spectrogram statistics and classifier output
- Per-frame bearing, ILD angle, GCC angle, fused angle
- Raw and bias-corrected TDOA values
- Voice activity status and confidence

---

## License

All rights reserved.
