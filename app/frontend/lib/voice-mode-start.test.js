import { afterEach, describe, expect, it } from 'vitest';
import { armVoiceStart, disarmVoiceStart, takeVoiceStart } from './voice-mode-start';

describe('voice start handoff', () => {
  afterEach(() => disarmVoiceStart());

  it('is taken once', () => {
    armVoiceStart(1000);
    expect(takeVoiceStart(2000)).toBe(true);
    expect(takeVoiceStart(2001)).toBe(false);
  });

  it('is false when never armed', () => {
    expect(takeVoiceStart()).toBe(false);
  });

  it('lapses', () => {
    armVoiceStart(0);
    expect(takeVoiceStart(30_001)).toBe(false);
  });

  it('can be disarmed after a failed start', () => {
    armVoiceStart(0);
    disarmVoiceStart();
    expect(takeVoiceStart(1)).toBe(false);
  });
});
