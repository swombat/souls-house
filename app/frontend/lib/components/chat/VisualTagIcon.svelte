<script>
  import spriteUrl from '../../../assets/visual-tag-icons.svg?url';
  import { visualTagIconName } from '$lib/visual-tags';

  let { icon = 'ChatCircle', size = '1em', weight = 'duotone', class: className = '' } = $props();
  const name = $derived(visualTagIconName(icon));
  const safeWeight = $derived(weight === 'duotone' ? 'duotone' : 'regular');
</script>

<svg
  xmlns="http://www.w3.org/2000/svg"
  width={size}
  height={size}
  viewBox="0 0 256 256"
  fill="currentColor"
  class={className}
  aria-hidden="true"
  focusable="false">
  <use href={`${spriteUrl}#${name}-${safeWeight}`} />
</svg>
