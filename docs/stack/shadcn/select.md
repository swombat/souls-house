# Select Component

## Installation

```bash
bunx shadcn-svelte@latest add select
```

## Usage

```svelte
<script>
  import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
  } from "$lib/components/ui/select";
  
  let value = "";
</script>

<!-- Basic select -->
<Select bind:value>
  <SelectTrigger class="w-[180px]">
    <SelectValue placeholder="Select a fruit" />
  </SelectTrigger>
  <SelectContent>
    <SelectItem value="apple">Apple</SelectItem>
    <SelectItem value="banana">Banana</SelectItem>
    <SelectItem value="orange">Orange</SelectItem>
  </SelectContent>
</Select>

<!-- With groups -->
<Select>
  <SelectTrigger class="w-[280px]">
    <SelectValue placeholder="Select a timezone" />
  </SelectTrigger>
  <SelectContent>
    <SelectGroup>
      <SelectLabel>North America</SelectLabel>
      <SelectItem value="est">Eastern Standard Time (EST)</SelectItem>
      <SelectItem value="cst">Central Standard Time (CST)</SelectItem>
      <SelectItem value="pst">Pacific Standard Time (PST)</SelectItem>
    </SelectGroup>
    <SelectSeparator />
    <SelectGroup>
      <SelectLabel>Europe</SelectLabel>
      <SelectItem value="gmt">Greenwich Mean Time (GMT)</SelectItem>
      <SelectItem value="cet">Central European Time (CET)</SelectItem>
    </SelectGroup>
  </SelectContent>
</Select>

<!-- With form -->
<form>
  <div class="grid gap-4">
    <Label for="email">Email</Label>
    <Select name="country" required>
      <SelectTrigger>
        <SelectValue placeholder="Select your country" />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value="us">United States</SelectItem>
        <SelectItem value="uk">United Kingdom</SelectItem>
        <SelectItem value="ca">Canada</SelectItem>
      </SelectContent>
    </Select>
  </div>
</form>

<!-- Disabled state -->
<Select disabled>
  <SelectTrigger class="w-[180px]">
    <SelectValue placeholder="Disabled" />
  </SelectTrigger>
  <SelectContent>
    <SelectItem value="option1">Option 1</SelectItem>
  </SelectContent>
</Select>

<!-- With icons -->
<Select>
  <SelectTrigger class="w-[240px]">
    <SelectValue placeholder="Select a status" />
  </SelectTrigger>
  <SelectContent>
    <SelectItem value="active">
      <div class="flex items-center">
        <span class="h-2 w-2 rounded-full bg-green-500 mr-2" />
        Active
      </div>
    </SelectItem>
    <SelectItem value="inactive">
      <div class="flex items-center">
        <span class="h-2 w-2 rounded-full bg-gray-500 mr-2" />
        Inactive
      </div>
    </SelectItem>
  </SelectContent>
</Select>
```

## Components

- `Select` - Root component
- `SelectTrigger` - Button that triggers the dropdown
- `SelectValue` - Displays selected value
- `SelectContent` - Dropdown content container
- `SelectItem` - Individual option
- `SelectGroup` - Group related options
- `SelectLabel` - Label for option groups
- `SelectSeparator` - Visual separator

## Props

### Select
- `value` - Selected value
- `disabled` - Disable select
- `name` - Form field name
- `required` - Mark as required

### SelectItem
- `value` - Option value
- `disabled` - Disable option

## Documentation

- [Official Select Documentation](https://www.shadcn-svelte.com/docs/components/select)
- [Bits UI Select](https://bits-ui.com/docs/components/select)
