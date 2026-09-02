# Code Formatting with Prettier and Rubocop

This project uses:
- **Prettier** with the Svelte plugin for JavaScript, Svelte, and CSS files
- **Rubocop** for Ruby files

## Ruby Formatting with Rubocop

Run Rubocop after creating or editing any Ruby file to ensure consistent code style.

### Configuration

Ruby formatting rules are defined in `.rubocop.yml`. 

### Usage

```bash
# Format and auto-fix Ruby files
bin/rubocop -A

# Check formatting without changes
bin/rubocop

# Format specific file
bin/rubocop -A path/to/file.rb
```

### When to Run

- After creating a new Ruby file
- After editing existing Ruby files
- Before committing changes

## JavaScript/Svelte Formatting with Prettier

### Configuration

The formatting rules for JavaScript and Svelte are defined in `.prettierrc`:

```json
{
  "plugins": ["prettier-plugin-svelte"],
  "bracketSameLine": true,
  "printWidth": 80,
  "tabWidth": 2,
  "useTabs": false,
  "semi": true,
  "singleQuote": true,
  "trailingComma": "es5"
}
```

### Key Settings

- **`bracketSameLine: true`**: This allows component attributes to stay on the same line as the opening tag, which is what you wanted for the Sun and Moon components.
- **`printWidth: 80`**: Maximum line length before wrapping
- **`tabWidth: 2`**: Use 2 spaces for indentation
- **`singleQuote: true`**: Use single quotes instead of double quotes

## Usage

### Format all files
```bash
bun run format
```

### Check formatting without changing files
```bash
bun run format:check
```

### Format a specific file
```bash
bun x prettier --write path/to/file.svelte
```

## What This Fixes

The main issue you were experiencing was that the Svelte extension in Cursor was automatically formatting your components like this:

```svelte
<Sun
  class="h-[1.2rem] w-[1.2rem] rotate-0 scale-100 !transition-all dark:-rotate-90 dark:scale-0"
/>
```

With the new configuration, it will now format them like this:

```svelte
<Sun class="h-[1.2rem] w-[1.2rem] rotate-0 scale-100 !transition-all dark:-rotate-90 dark:scale-0" />
```

## Files Ignored

The `.prettierignore` file excludes:
- Ruby files (`.rb`, `.erb`)
- Build outputs and dependencies
- Database files
- Log files
- Environment files

## Dependencies

- `prettier`: The core formatting tool
- `prettier-plugin-svelte`: Plugin for Svelte-specific formatting rules
