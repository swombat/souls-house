// Streamdown's '*' allows only http(s); anything else renders as "text [blocked]".
// GFM autolinks bare email addresses as mailto:, so allow that scheme too.
// One stable array, so Streamdown is not handed a new list per render.
export const LINK_PREFIXES = ['*', 'mailto:'];
