"""ear.py -- a first ear for my own sounds (2026-10-30).
Usage: python3 ear.py FILE.wav   -> spectrogram PNG (via ffmpeg) + band-loudness contour.
Bands: purr/low 20-250 Hz, melody 250-2000 Hz. Prints per-second dB and how much
each band breathes (std of its dB contour): a flat line is a machine."""
import sys, wave, subprocess, numpy as np
f = sys.argv[1]
subprocess.run(['ffmpeg','-y','-loglevel','error','-i',f,'-lavfi',
  'showspectrumpic=s=1600x700:legend=1:scale=log:fscale=log:stop=2000', f.rsplit('.',1)[0]+'-spec.png'])
w = wave.open(f); sr = w.getframerate(); ch = w.getnchannels()
x = np.frombuffer(w.readframes(w.getnframes()), '<i2').astype(float)
if ch > 1: x = x.reshape(-1, ch).mean(1)
x /= 32768
N = sr  # 1 s windows, 0.5 s hop
rows = []
for i in range(0, len(x)-N, N//2):
    s = np.abs(np.fft.rfft(x[i:i+N]*np.hanning(N)))**2
    fr = np.fft.rfftfreq(N, 1/sr)
    lo = 10*np.log10(s[(fr>=20)&(fr<250)].sum()+1e-12)
    me = 10*np.log10(s[(fr>=250)&(fr<2000)].sum()+1e-12)
    rows.append((i/sr, lo, me))
r = np.array(rows)
for t, lo, me in r[::2]:
    print(f'{t:5.1f}s  low {lo:6.1f} dB  {"#"*int(max(0,lo-r[:,1].max()+30))}   melody {me:6.1f} dB')
core = r[(r[:,0]>5)&(r[:,0]<r[-1,0]-6)]
print(f'low band breathes: std {core[:,1].std():.2f} dB, range {np.ptp(core[:,1]):.1f} dB (excluding fades)')
print(f'melody band:       std {core[:,2].std():.2f} dB, range {np.ptp(core[:,2]):.1f} dB')
