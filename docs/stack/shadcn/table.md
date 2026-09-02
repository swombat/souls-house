# Table Component

## Installation

```bash
bunx shadcn-svelte@latest add table
```

## Usage

```svelte
<script>
  import * as Table from "$lib/components/ui/table";
</script>

<!-- Basic table -->
<Table.Root>
  <Table.Caption>A list of your recent invoices.</Table.Caption>
  <Table.Header>
    <Table.Row>
      <Table.Head class="w-[100px]">Invoice</Table.Head>
      <Table.Head>Status</Table.Head>
      <Table.Head>Method</Table.Head>
      <Table.Head class="text-right">Amount</Table.Head>
    </Table.Row>
  </Table.Header>
  <Table.Body>
    <Table.Row>
      <Table.Cell class="font-medium">INV001</Table.Cell>
      <Table.Cell>Paid</Table.Cell>
      <Table.Cell>Credit Card</Table.Cell>
      <Table.Cell class="text-right">$250.00</Table.Cell>
    </Table.Row>
    <Table.Row>
      <Table.Cell class="font-medium">INV002</Table.Cell>
      <Table.Cell>Pending</Table.Cell>
      <Table.Cell>PayPal</Table.Cell>
      <Table.Cell class="text-right">$150.00</Table.Cell>
    </Table.Row>
    <Table.Row>
      <Table.Cell class="font-medium">INV003</Table.Cell>
      <Table.Cell>Unpaid</Table.Cell>
      <Table.Cell>Bank Transfer</Table.Cell>
      <Table.Cell class="text-right">$350.00</Table.Cell>
    </Table.Row>
  </Table.Body>
</Table.Root>

<!-- Table with data iteration -->
<script>
  const invoices = [
    { id: "INV001", status: "Paid", method: "Credit Card", amount: "$250.00" },
    { id: "INV002", status: "Pending", method: "PayPal", amount: "$150.00" },
    { id: "INV003", status: "Unpaid", method: "Bank Transfer", amount: "$350.00" },
    { id: "INV004", status: "Paid", method: "Credit Card", amount: "$450.00" },
    { id: "INV005", status: "Paid", method: "PayPal", amount: "$550.00" },
    { id: "INV006", status: "Pending", method: "Bank Transfer", amount: "$200.00" },
    { id: "INV007", status: "Unpaid", method: "Credit Card", amount: "$300.00" }
  ];
</script>

<div class="rounded-md border">
  <Table.Root>
    <Table.Header>
      <Table.Row>
        <Table.Head>Invoice</Table.Head>
        <Table.Head>Status</Table.Head>
        <Table.Head>Method</Table.Head>
        <Table.Head class="text-right">Amount</Table.Head>
      </Table.Row>
    </Table.Header>
    <Table.Body>
      {#each invoices as invoice}
        <Table.Row>
          <Table.Cell class="font-medium">{invoice.id}</Table.Cell>
          <Table.Cell>
            <span class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium
              {invoice.status === 'Paid' ? 'bg-green-100 text-green-800' :
               invoice.status === 'Pending' ? 'bg-yellow-100 text-yellow-800' :
               'bg-red-100 text-red-800'}">
              {invoice.status}
            </span>
          </Table.Cell>
          <Table.Cell>{invoice.method}</Table.Cell>
          <Table.Cell class="text-right">{invoice.amount}</Table.Cell>
        </Table.Row>
      {/each}
    </Table.Body>
  </Table.Root>
</div>

<!-- Table with actions -->
<script>
  import * as DropdownMenu from "$lib/components/ui/dropdown-menu";
  import { Button } from "$lib/components/ui/button";
  import { DotsThree, Pencil, Trash, Eye } from "phosphor-svelte";
  
  function viewInvoice(id) {
    console.log("View invoice:", id);
  }
  
  function editInvoice(id) {
    console.log("Edit invoice:", id);
  }
  
  function deleteInvoice(id) {
    console.log("Delete invoice:", id);
  }
</script>

<div class="rounded-md border">
  <Table.Root>
    <Table.Header>
      <Table.Row>
        <Table.Head>Invoice</Table.Head>
        <Table.Head>Status</Table.Head>
        <Table.Head>Method</Table.Head>
        <Table.Head>Amount</Table.Head>
        <Table.Head class="text-right">Actions</Table.Head>
      </Table.Row>
    </Table.Header>
    <Table.Body>
      {#each invoices as invoice}
        <Table.Row>
          <Table.Cell class="font-medium">{invoice.id}</Table.Cell>
          <Table.Cell>{invoice.status}</Table.Cell>
          <Table.Cell>{invoice.method}</Table.Cell>
          <Table.Cell>{invoice.amount}</Table.Cell>
          <Table.Cell class="text-right">
            <DropdownMenu.Root>
              <DropdownMenu.Trigger asChild>
                <Button variant="ghost" class="h-8 w-8 p-0">
                  <span class="sr-only">Open menu</span>
                  <DotsThree class="h-4 w-4" />
                </Button>
              </DropdownMenu.Trigger>
              <DropdownMenu.Content align="end">
                <DropdownMenu.Item on:click={() => viewInvoice(invoice.id)}>
                  <Eye class="mr-2 h-4 w-4" />
                  View
                </DropdownMenu.Item>
                <DropdownMenu.Item on:click={() => editInvoice(invoice.id)}>
                  <Pencil class="mr-2 h-4 w-4" />
                  Edit
                </DropdownMenu.Item>
                <DropdownMenu.Separator />
                <DropdownMenu.Item 
                  class="text-red-600" 
                  on:click={() => deleteInvoice(invoice.id)}
                >
                  <Trash class="mr-2 h-4 w-4" />
                  Delete
                </DropdownMenu.Item>
              </DropdownMenu.Content>
            </DropdownMenu.Root>
          </Table.Cell>
        </Table.Row>
      {/each}
    </Table.Body>
  </Table.Root>
</div>

<!-- Responsive table with scroll -->
<div class="rounded-md border overflow-hidden">
  <div class="overflow-x-auto">
    <Table.Root>
      <Table.Header>
        <Table.Row>
          <Table.Head class="min-w-[100px]">Invoice</Table.Head>
          <Table.Head class="min-w-[100px]">Status</Table.Head>
          <Table.Head class="min-w-[120px]">Method</Table.Head>
          <Table.Head class="min-w-[100px]">Customer</Table.Head>
          <Table.Head class="min-w-[120px]">Date</Table.Head>
          <Table.Head class="min-w-[100px] text-right">Amount</Table.Head>
        </Table.Row>
      </Table.Header>
      <Table.Body>
        <Table.Row>
          <Table.Cell>INV001</Table.Cell>
          <Table.Cell>Paid</Table.Cell>
          <Table.Cell>Credit Card</Table.Cell>
          <Table.Cell>John Doe</Table.Cell>
          <Table.Cell>2024-01-15</Table.Cell>
          <Table.Cell class="text-right">$250.00</Table.Cell>
        </Table.Row>
        <!-- More rows... -->
      </Table.Body>
    </Table.Root>
  </div>
</div>

<!-- Empty state -->
<div class="rounded-md border">
  <Table.Root>
    <Table.Header>
      <Table.Row>
        <Table.Head>Name</Table.Head>
        <Table.Head>Status</Table.Head>
        <Table.Head>Role</Table.Head>
        <Table.Head>Actions</Table.Head>
      </Table.Row>
    </Table.Header>
    <Table.Body>
      <Table.Row>
        <Table.Cell colSpan={4} class="h-24 text-center">
          No results found.
        </Table.Cell>
      </Table.Row>
    </Table.Body>
  </Table.Root>
</div>
```

## Components

- `Table.Root` - Table container
- `Table.Header` - Table header section
- `Table.Body` - Table body section
- `Table.Footer` - Table footer section (optional)
- `Table.Row` - Table row
- `Table.Head` - Table header cell
- `Table.Cell` - Table data cell
- `Table.Caption` - Table caption/title

## Props

### Table.Root
- `class` - Additional CSS classes

### Table.Header / Table.Body / Table.Footer
- `class` - Additional CSS classes

### Table.Row
- `class` - Additional CSS classes

### Table.Head / Table.Cell
- `colSpan` - Number of columns to span
- `class` - Additional CSS classes

## Styling Patterns

### Striped rows
```svelte
<Table.Body>
  {#each data as item, i}
    <Table.Row class={i % 2 === 0 ? "bg-muted/50" : ""}>
      <!-- cells -->
    </Table.Row>
  {/each}
</Table.Body>
```

### Hover effects
```svelte
<Table.Row class="hover:bg-muted/50">
  <!-- cells -->
</Table.Row>
```

### Fixed header
```svelte
<div class="relative max-h-[400px] overflow-auto">
  <Table.Root>
    <Table.Header class="sticky top-0 bg-background">
      <!-- header rows -->
    </Table.Header>
    <Table.Body>
      <!-- body rows -->
    </Table.Body>
  </Table.Root>
</div>
```

## Best Practices

- Use semantic HTML table elements
- Include table captions for accessibility
- Make tables responsive with horizontal scroll
- Provide clear column headers
- Use consistent alignment (numbers right-aligned)
- Show loading and empty states
- Consider pagination for large datasets

## Accessibility

- Proper table structure with thead, tbody
- Column headers with scope attributes
- Caption for table description
- Keyboard navigation support

## Documentation

- [Official Table Documentation](https://www.shadcn-svelte.com/docs/components/table)
