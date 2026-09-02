# DaisyUI Reference Guide

## IMPORTANT: Component Selection Priority

**ALWAYS prefer ShadcN Svelte components over DaisyUI components.**

Only use DaisyUI when:
- ShadcN doesn't have a similar component available
- Highly bespoke customization is needed that ShadcN doesn't support
- You need semantic utility classes for quick styling

## Installation & Setup

DaisyUI requires Tailwind CSS 4:

```bash
bun add --dev daisyui@latest
```

Configuration in CSS:
```css
@import "tailwindcss";
@plugin "daisyui";
```

## Core Concepts

### Semantic Color System
DaisyUI provides semantic color names that work across themes:
- `primary`, `secondary`, `accent`
- `neutral`
- `base-100`, `base-200`, `base-300`
- `info`, `success`, `warning`, `error`

### Usage Pattern
```html
<button class="btn btn-primary">Primary Button</button>
<div class="card bg-base-100">Card content</div>
```

## Key Components (Use Only When ShadcN Unavailable)

### Layout Components
- **Hero** - `hero` - Landing page sections
- **Footer** - `footer` - Page footers
- **Divider** - `divider` - Content separators

### Navigation
- **Navbar** - `navbar` - Top navigation bars
- **Breadcrumbs** - `breadcrumbs` - Navigation trails
- **Steps** - `steps` - Progress indicators
- **Pagination** - `pagination` - Page navigation

### Data Display
- **Table** - `table` - Data tables with styling
- **Chat** - `chat` - Chat message bubbles
- **Diff** - `diff` - Code/text comparisons
- **Countdown** - `countdown` - Timer displays
- **Progress** - `progress` - Progress bars
- **Rating** - `rating` - Star ratings

### Feedback
- **Alert** - `alert` - Status messages
- **Skeleton** - `skeleton` - Loading placeholders

### Utility Classes
- **Avatar** - `avatar` - Profile images/placeholders
- **Badge** - `badge` - Status indicators
- **Mask** - `mask` - Image masking utilities

## Essential Usage Examples

```html
<!-- Alert -->
<div class="alert alert-success">
  <span>Success message</span>
</div>

<!-- Hero Section -->
<div class="hero min-h-screen bg-base-200">
  <div class="hero-content">
    <h1 class="text-5xl font-bold">Hello World</h1>
  </div>
</div>

<!-- Table -->
<table class="table">
  <thead>
    <tr><th>Name</th><th>Job</th></tr>
  </thead>
  <tbody>
    <tr><td>John</td><td>Developer</td></tr>
  </tbody>
</table>

<!-- Progress -->
<progress class="progress progress-primary" value="70" max="100"></progress>
```

## Theming

DaisyUI supports multiple themes with CSS configuration:

```css
@plugin "daisyui" {
  themes: light --default, dark --prefersdark;
}
```

Themes automatically apply semantic colors across all components.

## Best Practices

1. **Prefer ShadcN first** - Only use DaisyUI for gaps in ShadcN coverage
2. **Use semantic colors** - `btn-primary` instead of `btn-blue-500`
3. **Combine with Tailwind** - `btn btn-primary px-8 py-4` for additional styling
4. **Responsive design** - Use Tailwind prefixes: `md:btn-lg`, `sm:hero-content`

## Full Documentation

For complete component documentation, visit: https://daisyui.com/llms.txt

**Remember: This is a fallback library. Always check ShadcN Svelte first for available components.**
