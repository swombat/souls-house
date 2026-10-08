<script>
  import { Badge } from '$lib/components/shadcn/badge/index.js';

  let { status } = $props();
</script>

<Badge variant={status === 'decided' ? 'secondary' : 'outline'}>
  {status === 'decided' ? 'Decided' : 'In progress'}
</Badge>
