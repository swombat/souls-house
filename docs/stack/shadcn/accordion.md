# Accordion Component

## Installation

```bash
bunx shadcn-svelte@latest add accordion
```

## Usage

```svelte
<script>
  import * as Accordion from "$lib/components/ui/accordion";
</script>

<Accordion.Root class="w-full">
  <Accordion.Item value="item-1">
    <Accordion.Trigger>Is it accessible?</Accordion.Trigger>
    <Accordion.Content>
      Yes. It adheres to the WAI-ARIA design pattern and is built with accessibility in mind.
    </Accordion.Content>
  </Accordion.Item>

  <Accordion.Item value="item-2">
    <Accordion.Trigger>Is it styled?</Accordion.Trigger>
    <Accordion.Content>
      Yes. It comes with default styles that match the other components.
    </Accordion.Content>
  </Accordion.Item>

  <Accordion.Item value="item-3">
    <Accordion.Trigger>Is it animated?</Accordion.Trigger>
    <Accordion.Content>
      Yes. It's animated by default with smooth expand and collapse transitions.
    </Accordion.Content>
  </Accordion.Item>
</Accordion.Root>
```

## Multiple Selection

```svelte
<Accordion.Root type="multiple" class="w-full">
  <Accordion.Item value="item-1">
    <Accordion.Trigger>Multiple selection enabled</Accordion.Trigger>
    <Accordion.Content>
      Multiple accordion items can be open at the same time.
    </Accordion.Content>
  </Accordion.Item>
  <!-- More items... -->
</Accordion.Root>
```

## Props

### Root
- `type` - 'single' or 'multiple' selection mode
- `collapsible` - Allow closing all items in single mode
- `value` - Controlled value(s)
- `class` - Additional CSS classes

### Item
- `value` - Unique identifier for the item
- `disabled` - Disable the accordion item
- `class` - Additional CSS classes

### Trigger
- `class` - Additional CSS classes

### Content
- `class` - Additional CSS classes

## Documentation

- [Official Accordion Documentation](https://www.shadcn-svelte.com/docs/components/accordion)
- [Bits UI Accordion Documentation](https://bits-ui.com/docs/components/accordion)
