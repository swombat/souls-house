# frozen_string_literal: true

# See config/vite_guard.rb: no Vite build without node_modules/.bin/vite.
require_relative "../vite_guard"
ViteGuard.install!
