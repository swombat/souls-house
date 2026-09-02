# Form Component

## Installation

```bash
bunx shadcn-svelte@latest add form
```

## Usage

```svelte
<script>
  import { superForm } from "sveltekit-superforms/client";
  import { zodClient } from "sveltekit-superforms/adapters";
  import * as Form from "$lib/components/ui/form";
  import { Input } from "$lib/components/ui/input";
  import { Button } from "$lib/components/ui/button";
  import { z } from "zod";
  
  const formSchema = z.object({
    username: z.string().min(2).max(50),
    email: z.string().email(),
    password: z.string().min(8)
  });
  
  const form = superForm(data.form, {
    validators: zodClient(formSchema)
  });
  
  const { form: formData, enhance } = form;
</script>

<!-- Basic form -->
<form method="POST" use:enhance>
  <Form.Field {form} name="username">
    <Form.Control let:attrs>
      <Form.Label>Username</Form.Label>
      <Input {...attrs} bind:value={$formData.username} />
    </Form.Control>
    <Form.Description>
      This is your public display name.
    </Form.Description>
    <Form.FieldErrors />
  </Form.Field>
  
  <Form.Field {form} name="email">
    <Form.Control let:attrs>
      <Form.Label>Email</Form.Label>
      <Input {...attrs} type="email" bind:value={$formData.email} />
    </Form.Control>
    <Form.FieldErrors />
  </Form.Field>
  
  <Form.Field {form} name="password">
    <Form.Control let:attrs>
      <Form.Label>Password</Form.Label>
      <Input {...attrs} type="password" bind:value={$formData.password} />
    </Form.Control>
    <Form.Description>
      Must be at least 8 characters.
    </Form.Description>
    <Form.FieldErrors />
  </Form.Field>
  
  <Button type="submit">Submit</Button>
</form>

<!-- With select and textarea -->
<form method="POST" use:enhance>
  <Form.Field {form} name="bio">
    <Form.Control let:attrs>
      <Form.Label>Bio</Form.Label>
      <Textarea 
        {...attrs} 
        placeholder="Tell us about yourself" 
        bind:value={$formData.bio} 
      />
    </Form.Control>
    <Form.FieldErrors />
  </Form.Field>
  
  <Form.Field {form} name="role">
    <Form.Control let:attrs>
      <Form.Label>Role</Form.Label>
      <Select bind:value={$formData.role}>
        <SelectTrigger {...attrs}>
          <SelectValue placeholder="Select a role" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="admin">Admin</SelectItem>
          <SelectItem value="user">User</SelectItem>
        </SelectContent>
      </Select>
    </Form.Control>
    <Form.FieldErrors />
  </Form.Field>
</form>
```

## Schema Validation

```javascript
import { z } from "zod";

// Define schema
const schema = z.object({
  username: z.string()
    .min(2, "Username must be at least 2 characters")
    .max(50, "Username must be less than 50 characters"),
  email: z.string()
    .email("Invalid email address"),
  age: z.number()
    .min(18, "Must be at least 18 years old"),
  website: z.string()
    .url("Invalid URL")
    .optional(),
  terms: z.boolean()
    .refine(val => val === true, {
      message: "You must accept the terms"
    })
});
```

## Components

- `Form.Field` - Field wrapper with validation
- `Form.Control` - Control wrapper providing attrs
- `Form.Label` - Field label
- `Form.Description` - Helper text
- `Form.FieldErrors` - Validation errors
- `Form.Button` - Submit button

## Server-side Setup

```javascript
// +page.server.js
import { superValidate } from "sveltekit-superforms/server";
import { formSchema } from "./schema";
import { fail } from "@sveltejs/kit";

export const load = async () => {
  const form = await superValidate(formSchema);
  return { form };
};

export const actions = {
  default: async ({ request }) => {
    const form = await superValidate(request, formSchema);
    
    if (!form.valid) {
      return fail(400, { form });
    }
    
    // Process form data
    console.log(form.data);
    
    return { form };
  }
};
```

## Documentation

- [Official Form Documentation](https://www.shadcn-svelte.com/docs/components/form)
- [Formsnap Documentation](https://formsnap.dev/docs)
- [Superforms Documentation](https://superforms.app/)
