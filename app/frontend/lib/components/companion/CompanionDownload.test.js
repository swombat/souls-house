import { fireEvent, render, screen } from '@testing-library/svelte';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { writable } from 'svelte/store';
import { beforeEach, expect, test, vi } from 'vitest';

const { pageStore, copyText } = vi.hoisted(() => ({
  pageStore: { current: null },
  copyText: vi.fn(),
}));

vi.mock('@inertiajs/svelte', () => {
  const store = writable({ props: { site_settings: {} } });
  pageStore.current = store;
  return { page: store };
});
vi.mock('$lib/clipboard', () => ({ copyText }));

import CompanionDownload from './CompanionDownload.svelte';

beforeEach(() => {
  copyText.mockReset();
  copyText.mockResolvedValue(true);
  pageStore.current.set({ props: { site_settings: {} } });
});

test('shows the Linux one-line download-to-temp-file installer with copy, inspect-first, and manual tarballs', async () => {
  const base = 'https://github.com/swombat/souls-house-companion/releases/download/v0.9.0';
  const installerUrl = `${base}/install-linux.sh`;
  const installerSha = '11'.repeat(32);
  const amdUrl = `${base}/souls-house-companion-v0.9.0-linux-amd64.tar.gz`;
  const amdSha = '22'.repeat(32);
  pageStore.current.set({
    props: {
      site_settings: {
        companion_linux_installer_download_url: installerUrl,
        companion_linux_installer_download_sha256: installerSha,
        companion_linux_amd64_download_url: amdUrl,
        companion_linux_amd64_download_sha256: amdSha,
      },
    },
  });

  render(CompanionDownload);
  const cmd = screen.getByTestId('companion-linux-command').textContent;
  expect(cmd).toContain('mktemp');
  expect(cmd).toContain(installerUrl);
  expect(cmd).toContain(installerSha);
  expect(cmd).toContain('sha256sum -c --quiet');
  expect(cmd).toContain('sh "$f"');
  expect(cmd.indexOf('sha256sum -c --quiet')).toBeLessThan(cmd.indexOf('sh "$f"'));
  expect(cmd).not.toMatch(/\|\s*sh\b/);

  const inspect = screen.getByTestId('companion-linux-inspect');
  expect(inspect).toHaveAttribute('href', installerUrl);
  expect(screen.getByTestId('companion-linux-installer-sha256')).toHaveTextContent(installerSha);

  await fireEvent.click(screen.getByTestId('companion-linux-copy'));
  expect(copyText).toHaveBeenCalledWith(cmd);
  expect(screen.getByTestId('companion-linux-copy')).toHaveTextContent('Copied');

  expect(screen.getByTestId('companion-linux-manual')).toBeInTheDocument();
  expect(screen.getByTestId('companion-download-linux-amd64')).toHaveAttribute('href', amdUrl);
  expect(screen.getByTestId('companion-linux-amd64-sha256')).toHaveTextContent(amdSha);
});

test('generated one-liner refuses checksum mismatch without running sh and preserves nonzero exit after cleanup', () => {
  const dir = mkdtempSync(join(tmpdir(), 'companion-oneliner-'));
  try {
    const sentinel = join(dir, 'ran');
    const fakeScript = `#!/bin/sh\necho ran > '${sentinel}'\nexit 7\n`;
    const matchingSha = createHash('sha256').update(fakeScript).digest('hex');
    const wrongSha = '0'.repeat(64);
    const payloadPath = join(dir, 'payload.sh');
    writeFileSync(payloadPath, fakeScript, { mode: 0o644 });

    // Fake curl that copies payload.sh to the -o destination.
    const fakeBin = join(dir, 'bin');
    const fakeCurl = join(dir, 'curl');
    writeFileSync(
      fakeCurl,
      `#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\n  if [ "$1" = "-o" ]; then cp '${payloadPath}' "$2"; exit 0; fi\n  shift\ndone\nexit 1\n`,
      { mode: 0o755 }
    );
    const env = { ...process.env, PATH: `${dir}:${process.env.PATH}`, TMPDIR: dir };
    const url = 'https://github.com/swombat/souls-house-companion/releases/download/v0.9.0/install-linux.sh';

    // 1. Checksum mismatch: exits nonzero and never executes the downloaded script.
    pageStore.current.set({
      props: {
        site_settings: {
          companion_linux_installer_download_url: url,
          companion_linux_installer_download_sha256: wrongSha,
        },
      },
    });
    const { unmount } = render(CompanionDownload);
    const badCmd = screen.getByTestId('companion-linux-command').textContent;
    unmount();

    const badRun = spawnSync('sh', ['-c', badCmd], { env, encoding: 'utf8' });
    expect(badRun.status).not.toBe(0);
    expect(existsSync(sentinel)).toBe(false);

    // 2. Matching checksum + installer exits 7: runs script, cleans up, preserves exit code 7.
    pageStore.current.set({
      props: {
        site_settings: {
          companion_linux_installer_download_url: url,
          companion_linux_installer_download_sha256: matchingSha,
        },
      },
    });
    render(CompanionDownload);
    const okCmd = screen.getByTestId('companion-linux-command').textContent;
    const okRun = spawnSync('sh', ['-c', okCmd], { env, encoding: 'utf8' });
    expect(okRun.status).toBe(7);
    expect(existsSync(sentinel)).toBe(true);
    expect(fakeBin).toBeTruthy();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('renders manual tarballs directly when only tarballs are configured', () => {
  const amdUrl = 'https://github.com/swombat/souls-house-companion/releases/download/v0.8.0/companion-amd64.tar.gz';
  const amdSha = 'ab'.repeat(32);
  pageStore.current.set({
    props: {
      site_settings: {
        companion_linux_amd64_download_url: amdUrl,
        companion_linux_amd64_download_sha256: amdSha,
      },
    },
  });

  render(CompanionDownload);
  expect(screen.queryByTestId('companion-linux-installer')).not.toBeInTheDocument();
  expect(screen.queryByTestId('companion-linux-manual')).not.toBeInTheDocument();
  expect(screen.getByTestId('companion-download-linux-amd64')).toHaveAttribute('href', amdUrl);
});
