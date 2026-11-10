<script>
  import { Badge } from '$lib/components/shadcn/badge/index.js';

  let { availability } = $props();
</script>

<Badge variant={availability === 'included' ? 'secondary' : 'outline'}>
  {availability === 'included' ? 'Already in the house' : 'Install separately'}
</Badge>
