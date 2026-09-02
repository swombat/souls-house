# Forms Documentation

This document explains the Form framework used throughout the HelixKit application for consistent form handling, validation, and user experience.

## Overview

The Form framework provides a reusable component that handles:
- Form submission via Inertia.js
- Loading states and disabled inputs during submission
- Success and error message display
- Consistent styling and layout
- Cancel/success callbacks for navigation

## The Form Component

The central `Form.svelte` component is located at `/app/frontend/lib/components/forms/Form.svelte`.

### Basic Usage

```svelte
<script>
  import Form from '$lib/components/forms/Form.svelte';
  import Input from '$lib/components/shadcn/input/input.svelte';
  import Label from '$lib/components/shadcn/label/label.svelte';
  
  let formData = $state({
    name: '',
    email: ''
  });
</script>

<Form
  action="/users"
  method="post"
  data={() => formData}
  title="Create User"
  description="Fill in the user details"
  submitLabel="Create"
  submitLabelProcessing="Creating...">
  
  <div>
    <Label for="name">Name</Label>
    <Input id="name" bind:value={formData.name} required />
  </div>
  
  <div>
    <Label for="email">Email</Label>
    <Input id="email" type="email" bind:value={formData.email} required />
  </div>
</Form>
```

### Props

| Prop | Type | Default | Description |
|------|------|---------|-------------|
| `action` | string | required | The URL/route to submit the form to |
| `method` | string | 'post' | HTTP method (post, patch, put, delete) |
| `data` | function \| object | {} | Form data, can be a function returning data |
| `title` | string | required | Form title displayed in the card header |
| `description` | string | null | Optional description below the title |
| `submitLabel` | string | 'Save' | Text for the submit button |
| `submitLabelProcessing` | string | 'Saving...' | Text shown while processing |
| `showCancel` | boolean | true | Whether to show the cancel button |
| `cancelLabel` | string | 'Cancel' | Text for the cancel button |
| `onCancel` | function | null | Callback when cancel is clicked |
| `onSuccess` | function | null | Callback on successful submission |
| `onError` | function | null | Callback on submission error |
| `onFinish` | function | null | Callback when submission completes |
| `preserveState` | boolean | false | Preserve component state after submission |
| `narrow` | boolean | false | Use narrow layout (max-w-lg instead of max-w-2xl) |

### Layout Options

Forms can be displayed in two widths:

1. **Standard width** (default): Uses `max-w-2xl` for wider forms
2. **Narrow width**: Pass `narrow` prop for `max-w-lg` width, ideal for login/signup forms

```svelte
<!-- Narrow form for authentication -->
<Form
  narrow
  title="Log in"
  ...>
  <!-- form fields -->
</Form>
```

## Form Components

All form components follow a consistent pattern and accept `onCancel` and `onSuccess` props for handling navigation.

### Authentication Forms

#### LoginForm
- **Location**: `/app/frontend/lib/components/forms/LoginForm.svelte`
- **Purpose**: User login
- **Width**: Narrow
- **Special features**: Forgot password link, signup link

#### SignupForm
- **Location**: `/app/frontend/lib/components/forms/SignupForm.svelte`
- **Purpose**: User registration
- **Width**: Narrow
- **Special features**: Account creation notice, login link

#### ChangePasswordForm
- **Location**: `/app/frontend/lib/components/forms/ChangePasswordForm.svelte`
- **Purpose**: Change password for authenticated users
- **Width**: Narrow
- **Fields**: Current password, new password, confirmation

#### EditPasswordForm
- **Location**: `/app/frontend/lib/components/forms/EditPasswordForm.svelte`
- **Purpose**: Reset password with token
- **Width**: Narrow
- **Fields**: New password, confirmation

#### ResetPasswordForm
- **Location**: `/app/frontend/lib/components/forms/ResetPasswordForm.svelte`
- **Purpose**: Request password reset
- **Width**: Narrow
- **Fields**: Email address

### User Settings Forms

#### UserSettingsForm
- **Location**: `/app/frontend/lib/components/forms/UserSettingsForm.svelte`
- **Purpose**: Edit user profile settings
- **Width**: Standard
- **Fields**: First name, last name, timezone

## Creating a New Form

To create a new form using the framework:

1. Create a new component in `/app/frontend/lib/components/forms/`
2. Import the Form component and necessary inputs
3. Define reactive state for form data
4. Use the Form component with appropriate props

### Example: Creating a Contact Form

```svelte
<script>
  import Form from './Form.svelte';
  import Input from '$lib/components/shadcn/input/input.svelte';
  import Textarea from '$lib/components/shadcn/textarea/textarea.svelte';
  import Label from '$lib/components/shadcn/label/label.svelte';
  import { contactPath } from '@/routes';

  let { onCancel, onSuccess } = $props();

  let contactData = $state({
    name: '',
    email: '',
    message: ''
  });
</script>

<Form
  action={contactPath()}
  method="post"
  data={() => contactData}
  title="Contact Us"
  description="Send us a message"
  submitLabel="Send Message"
  submitLabelProcessing="Sending..."
  {onCancel}
  {onSuccess}>
  
  <div>
    <Label for="name">Name</Label>
    <Input 
      id="name" 
      bind:value={contactData.name} 
      required />
  </div>
  
  <div>
    <Label for="email">Email</Label>
    <Input 
      id="email" 
      type="email" 
      bind:value={contactData.email} 
      required />
  </div>
  
  <div>
    <Label for="message">Message</Label>
    <Textarea 
      id="message" 
      bind:value={contactData.message} 
      required />
  </div>
</Form>
```

## Using Forms in Pages

When using a form component in a page, handle navigation through callbacks:

```svelte
<script>
  import { router } from '@inertiajs/svelte';
  import ContactForm from '$lib/components/forms/ContactForm.svelte';
  import { rootPath } from '@/routes';

  function handleCancel() {
    router.visit(rootPath());
  }

  function handleSuccess() {
    router.visit(rootPath());
  }
</script>

<ContactForm 
  onCancel={handleCancel} 
  onSuccess={handleSuccess} />
```

## Error Handling

The Form component automatically handles and displays errors from the server:

1. **Flash messages**: Displayed as alerts above the form
2. **Field errors**: Can be displayed using InputError components (though the new Form framework handles general errors)
3. **Processing state**: Disables form submission during processing

## Best Practices

1. **Always use the Form component** for consistency across the application
2. **Use the `narrow` prop** for authentication and simple forms
3. **Provide meaningful labels** for submit button states
4. **Handle navigation** through onCancel and onSuccess callbacks
5. **Use reactive state** with `$state()` for form data
6. **Return data as a function** in the `data` prop to ensure reactivity

## Testing

Forms using this framework are tested with Playwright component tests. See `/test/playwright/` for test examples.

### Running Tests

```bash
bun run test:component
```

## Migration Guide

If you have an old form using `useForm` directly, follow these steps to migrate:

1. Remove `useForm` import and form submission handler
2. Replace Card components with Form component
3. Convert form data to reactive state with `$state()`
4. Pass appropriate props to Form component
5. Move submit button content to submitLabel props
6. Add narrow prop if appropriate

### Before (Old Pattern)
```svelte
<script>
  import { useForm } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card/index.js';
  
  const form = useForm({
    email: null
  });
  
  function submit(e) {
    e.preventDefault();
    $form.post('/login');
  }
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Login</Card.Title>
  </Card.Header>
  <Card.Content>
    <form onsubmit={submit}>
      <!-- fields -->
      <Button type="submit">Log in</Button>
    </form>
  </Card.Content>
</Card.Root>
```

### After (New Pattern)
```svelte
<script>
  import Form from './Form.svelte';
  
  let loginData = $state({
    email: ''
  });
</script>

<Form
  action="/login"
  method="post"
  data={() => loginData}
  title="Login"
  submitLabel="Log in"
  narrow>
  <!-- fields -->
</Form>
```
