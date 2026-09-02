# Data Table Component

## Installation

```bash
bunx shadcn-svelte@latest add data-table
```

## Usage

```svelte
<script>
  import { DataTable } from "$lib/components/ui/data-table";
  import { Button } from "$lib/components/ui/button";
  import { ArrowsDownUp } from "phosphor-svelte";
  
  const data = [
    { id: "m5gr84i9", amount: 316, status: "success", email: "ken99@yahoo.com" },
    { id: "3u1reuv4", amount: 242, status: "success", email: "Abe45@gmail.com" },
    { id: "derv1ws0", amount: 837, status: "processing", email: "Monserrat44@gmail.com" },
  ];
  
  const columns = [
    {
      accessorKey: "status",
      header: "Status",
    },
    {
      accessorKey: "email",
      header: ({ column }) => {
        return Button({
          variant: "ghost",
          onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
          children: [
            "Email",
            ArrowsDownUp({ class: "ml-2 h-4 w-4" })
          ]
        });
      },
    },
    {
      accessorKey: "amount",
      header: () => "Amount",
      cell: ({ row }) => {
        const amount = parseFloat(row.getValue("amount"));
        const formatted = new Intl.NumberFormat("en-US", {
          style: "currency",
          currency: "USD",
        }).format(amount);
        return `<div class="text-right font-medium">${formatted}</div>`;
      },
    },
  ];
</script>

<DataTable {columns} {data} />
```

## With Pagination

```svelte
<script>
  import { DataTable } from "$lib/components/ui/data-table";
  import { Button } from "$lib/components/ui/button";
  import { Input } from "$lib/components/ui/input";
  
  let table;
  let globalFilter = "";
</script>

<div class="w-full">
  <div class="flex items-center py-4">
    <Input
      placeholder="Filter emails..."
      bind:value={globalFilter}
      on:input={(e) => table?.setGlobalFilter(e.target.value)}
      class="max-w-sm"
    />
  </div>
  
  <DataTable {columns} {data} bind:table />
  
  <div class="flex items-center justify-end space-x-2 py-4">
    <Button
      variant="outline"
      size="sm"
      on:click={() => table?.previousPage()}
      disabled={!table?.getCanPreviousPage()}
    >
      Previous
    </Button>
    <Button
      variant="outline"
      size="sm"
      on:click={() => table?.nextPage()}
      disabled={!table?.getCanNextPage()}
    >
      Next
    </Button>
  </div>
</div>
```

## Column Configuration

```svelte
<script>
  const columns = [
    {
      id: "select",
      header: ({ table }) => {
        return Checkbox({
          checked: table.getIsAllPageRowsSelected(),
          indeterminate: table.getIsSomePageRowsSelected(),
          onCheckedChange: (value) => table.toggleAllPageRowsSelected(!!value),
        });
      },
      cell: ({ row }) => {
        return Checkbox({
          checked: row.getIsSelected(),
          onCheckedChange: (value) => row.toggleSelected(!!value),
        });
      },
      enableSorting: false,
      enableHiding: false,
    },
    {
      accessorKey: "status",
      header: "Status",
      cell: ({ row }) => {
        const status = row.getValue("status");
        return `<div class="capitalize">${status}</div>`;
      },
    },
    {
      id: "actions",
      enableHiding: false,
      cell: ({ row }) => {
        const payment = row.original;
        return DropdownMenu({
          trigger: Button({ variant: "ghost", class: "h-8 w-8 p-0" }),
          content: [
            DropdownMenuItem({ onclick: () => copyId(payment.id) }, "Copy payment ID"),
            DropdownMenuSeparator(),
            DropdownMenuItem("View customer"),
            DropdownMenuItem("View payment details"),
          ]
        });
      },
    },
  ];
</script>
```

## Props

### DataTable
- `columns` - Column definitions
- `data` - Table data
- `table` - Table instance (bindable)
- `class` - Additional CSS classes

### Column Definition
- `accessorKey` - Data property key
- `header` - Header content or function
- `cell` - Cell content function
- `enableSorting` - Enable sorting for column
- `enableHiding` - Enable hiding for column

## Features

- Sorting
- Filtering
- Pagination
- Row selection
- Column visibility
- Responsive design

## Documentation

- [Official Data Table Documentation](https://www.shadcn-svelte.com/docs/components/data-table)
- [TanStack Table Documentation](https://tanstack.com/table/latest)
