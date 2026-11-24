import { fireEvent, render, screen } from '@testing-library/svelte';
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
  expect(cmd).toContain('sh "$f"');
  expect(cmd).not.toContain('| sh');
  expect(cmd).not.toContain('|sh');

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
