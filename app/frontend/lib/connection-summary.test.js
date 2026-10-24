import { describe, expect, it } from 'vitest';
import { accessSummary, attentionLabel, connectionTitle, startsOpen } from './connection-summary';

const resident = (name, enabled) => ({ id: name, name, enabled });

describe('accessSummary', () => {
  it('names the residents with access while they fit', () => {
    const connection = { residents: [resident('Lume', true), resident('Mira', true), resident('Ada', false)] };
    expect(accessSummary(connection)).toEqual({ text: 'Lume, Mira', none: false });
  });

  it('counts when there are too many names', () => {
    const residents = ['A', 'B', 'C', 'D', 'E'].map((name, index) => resident(name, index < 4));
    expect(accessSummary({ residents })).toEqual({ text: '4 of 5 residents', none: false });
  });

  it('says plainly when nobody has access', () => {
    expect(accessSummary({ residents: [resident('Lume', false)] })).toEqual({
      text: 'No residents have access',
      none: true,
    });
    expect(accessSummary({ residents: [] }).none).toBe(true);
  });
});

describe('attentionLabel', () => {
  it('flags connections that cannot be used yet', () => {
    expect(attentionLabel({ provider: 'github', status: 'reauthorizing' })).toBe('Reconnect needed');
    expect(attentionLabel({ provider: 'whatsapp', status: 'reauthorizing' })).toBe('Pair again');
    expect(attentionLabel({ provider: 'telegram', status: 'pairing' })).toBe('Waiting for sign-in');
    expect(attentionLabel({ provider: 'whatsapp', status: 'pairing' })).toBe('Waiting for pairing');
    expect(attentionLabel({ provider: 'whatsapp', status: 'revoked', comms: { unpair_pending: true } })).toBe(
      'Unlinking device'
    );
  });

  it('leaves healthy connections closed', () => {
    const connection = { provider: 'porkbun', status: 'connected' };
    expect(attentionLabel(connection)).toBeNull();
    expect(startsOpen(connection)).toBe(false);
    expect(startsOpen({ provider: 'github', status: 'reauthorizing' })).toBe(true);
  });
});

describe('connectionTitle', () => {
  it('uses the Google identity, and the label otherwise', () => {
    expect(connectionTitle({ provider: 'google_workspace', identity: 'a@b.c', label: 'Google' })).toBe('a@b.c');
    expect(connectionTitle({ provider: 'porkbun', label: 'Porkbun (swombat)' })).toBe('Porkbun (swombat)');
  });
});
