// Headphones that join in the middle of voice mode (jBVWGj; Daniel's Pixel,
// 6 Nov: Bluetooth headphones connected mid-conversation and the voice stayed
// on the phone speaker).
//
// On Android, Chrome puts audio in call mode while the microphone is open and
// picks the call's route when the microphone opens; a headset that arrives
// later is not taken up. Reopening the microphone makes it choose again. So
// the panel watches for the audio devices changing and reopens the microphone
// between turns (never in the middle of one).
//
// Devices arrive and leave in bursts (a headset is an input and an output),
// so a change is reported once the list has been still for settleMs.

export function watchDevices({ mediaDevices = globalThis.navigator?.mediaDevices, onchange, settleMs = 800 } = {}) {
  if (!mediaDevices?.addEventListener) return () => {};
  let timer = null;
  const changed = () => {
    clearTimeout(timer);
    timer = setTimeout(() => onchange?.(), settleMs);
  };
  mediaDevices.addEventListener('devicechange', changed);
  return () => {
    clearTimeout(timer);
    mediaDevices.removeEventListener?.('devicechange', changed);
  };
}
