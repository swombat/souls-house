import { test, expect } from '@playwright/experimental-ct-svelte';
import UserEditPage from '../../../app/frontend/pages/user/edit.svelte';
import UserEditPasswordPage from '../../../app/frontend/pages/user/edit_password.svelte';

test.describe('User Settings Tests', () => {
  test.describe('User Profile Settings Page', () => {
    test('should render user settings page with all elements', async ({ mount }) => {
      const props = {
        user: {
          id: 1,
          email_address: 'test@example.com',
          first_name: 'Test',
          last_name: 'User',
          chat_colour: null,
        },
        timezones: [],
        current_account: {
          id: 1,
          name: "Test User's Account",
          account_type: 0,
          slug: 'test-users-account',
        },
      };

      const page = await mount(UserEditPage, { props });

      // Check page title/heading (includes user's name)
      await expect(page).toContainText('User Settings');

      // Check form fields are present
      await expect(page.locator('input[name="first_name"], input#first_name')).toBeVisible();
      await expect(page.locator('input[name="last_name"], input#last_name')).toBeVisible();
      await expect(page.locator('input[name="email_address"], input#email_address, input[type="email"]')).toBeVisible();

      // Check submit button
      await expect(page.locator('button[type="submit"]')).toBeVisible();
      await expect(page.locator('button[type="submit"]')).toContainText('Save Changes');

      // The UserSettingsForm doesn't have a change password link
      // That would be in a different part of the app
    });

    test('should display current user information', async ({ mount }) => {
      const props = {
        user: {
          id: 1,
          email_address: 'john.doe@example.com',
          first_name: 'John',
          last_name: 'Doe',
          chat_colour: null,
        },
        timezones: [],
        current_account: {
          id: 1,
          name: "John's Account",
          account_type: 0,
          slug: 'johns-account',
        },
      };

      const page = await mount(UserEditPage, { props });

      // Check that current values are displayed
      const firstNameInput = page.locator('input[name="first_name"], input#first_name');
      const lastNameInput = page.locator('input[name="last_name"], input#last_name');
      const emailInput = page.locator('input[name="email_address"], input#email_address, input[type="email"]');

      await expect(firstNameInput).toHaveValue('John');
      await expect(lastNameInput).toHaveValue('Doe');
      await expect(emailInput).toHaveValue('john.doe@example.com');
    });

    test('should allow editing user information', async ({ mount }) => {
      const props = {
        user: {
          id: 1,
          email_address: 'test@example.com',
          first_name: 'Test',
          last_name: 'User',
          chat_colour: null,
        },
        timezones: [],
        current_account: {
          id: 1,
          name: 'Test Account',
          account_type: 0,
          slug: 'test-account',
        },
      };

      const component = await mount(UserEditPage, { props });

      // Wait for the form to be visible
      await expect(component.locator('form, div').first()).toBeVisible();

      const firstNameInput = component.locator('input#first_name');
      const lastNameInput = component.locator('input#last_name');
      const emailInput = component.locator('input#email');

      // Clear and type new values in editable fields
      await firstNameInput.clear();
      await firstNameInput.fill('Updated');

      await lastNameInput.clear();
      await lastNameInput.fill('Name');

      // Email field is disabled, so just verify it shows the correct value
      await expect(emailInput).toBeDisabled();
      await expect(emailInput).toHaveValue('test@example.com');

      // Verify new values in editable fields
      await expect(firstNameInput).toHaveValue('Updated');
      await expect(lastNameInput).toHaveValue('Name');
    });

    test('should submit profile update form', async ({ mount, page }) => {
      const requests = [];
      await page.route('**/user', async (route) => {
        requests.push({ method: route.request().method(), data: route.request().postDataJSON() });
        await route.fulfill({ status: 200, json: {} });
      });
      const props = {
        user: {
          id: 1,
          email_address: 'test@example.com',
          first_name: 'Test',
          last_name: 'User',
          chat_colour: null,
        },
        timezones: [],
        current_account: {
          id: 1,
          name: 'Test Account',
          account_type: 0,
          slug: 'test-account',
        },
      };

      const component = await mount(UserEditPage, { props });

      // Update a field
      const firstNameInput = component.locator('input#first_name');
      await firstNameInput.clear();
      await firstNameInput.fill('NewName');

      // Verify form can be submitted
      const submitButton = component.locator('button[type="submit"]');
      await expect(submitButton).toBeEnabled();
      await expect(submitButton).toContainText('Save Changes');

      await submitButton.click();
      await expect
        .poll(() => requests)
        .toEqual([{ method: 'PATCH', data: { user: { ...props.user, first_name: 'NewName', timezone: '' } } }]);
      await expect(submitButton).toBeEnabled();
    });
  });

  test.describe('Change Password Page', () => {
    test('should render change password page with all elements', async ({ mount }) => {
      const props = {
        user: {
          id: 1,
          email_address: 'test@example.com',
          first_name: 'Test',
          last_name: 'User',
        },
      };

      const page = await mount(UserEditPasswordPage, { props });

      // Check page title
      await expect(page).toContainText(/change password|update password|password/i);

      // Check form fields
      await expect(page.locator('input[type="password"]').first()).toBeVisible(); // Current password
      await expect(page.locator('input[type="password"]').nth(1)).toBeVisible(); // New password
      await expect(page.locator('input[type="password"]').nth(2)).toBeVisible(); // Confirm password

      // Check submit button
      await expect(page.locator('button[type="submit"]')).toBeVisible();
      await expect(page.locator('button[type="submit"]')).toContainText('Update Password');

      // Check for cancel button (from the Form component)
      await expect(page.locator('button').filter({ hasText: /cancel/i })).toBeVisible();
    });

    test('should validate password fields are required', async ({ mount }) => {
      const props = {
        user: {
          id: 1,
          email_address: 'test@example.com',
          first_name: 'Test',
          last_name: 'User',
        },
      };

      const component = await mount(UserEditPasswordPage, { props });

      const currentPasswordInput = component.locator('input[type="password"]').first();
      const newPasswordInput = component.locator('input[type="password"]').nth(1);
      const confirmPasswordInput = component.locator('input[type="password"]').nth(2);

      // Check required attributes
      await expect(currentPasswordInput).toHaveAttribute('required', '');
      await expect(newPasswordInput).toHaveAttribute('required', '');
      await expect(confirmPasswordInput).toHaveAttribute('required', '');
    });

    test('should accept password input', async ({ mount }) => {
      const props = {
        user: {
          id: 1,
          email_address: 'test@example.com',
          first_name: 'Test',
          last_name: 'User',
        },
      };

      const component = await mount(UserEditPasswordPage, { props });

      const currentPasswordInput = component.locator('input[type="password"]').first();
      const newPasswordInput = component.locator('input[type="password"]').nth(1);
      const confirmPasswordInput = component.locator('input[type="password"]').nth(2);

      // Type in passwords
      await currentPasswordInput.fill('currentpass123');
      await newPasswordInput.fill('newpass456');
      await confirmPasswordInput.fill('newpass456');

      // Verify values
      await expect(currentPasswordInput).toHaveValue('currentpass123');
      await expect(newPasswordInput).toHaveValue('newpass456');
      await expect(confirmPasswordInput).toHaveValue('newpass456');
    });

    test('should submit password change form', async ({ mount, page }) => {
      const requests = [];
      await page.route('**/user/password', async (route) => {
        requests.push({ method: route.request().method(), data: route.request().postDataJSON() });
        await route.fulfill({ status: 200, json: {} });
      });
      const props = {
        user: {
          id: 1,
          email_address: 'test@example.com',
          first_name: 'Test',
          last_name: 'User',
        },
      };

      const component = await mount(UserEditPasswordPage, { props });

      // Fill in all password fields
      await component.locator('input[type="password"]').first().fill('password123');
      await component.locator('input[type="password"]').nth(1).fill('newpassword456');
      await component.locator('input[type="password"]').nth(2).fill('newpassword456');

      // Verify form can be submitted
      const submitButton = component.locator('button[type="submit"]');
      await expect(submitButton).toBeEnabled();

      const destination = new URL('/', page.url()).href;
      await page.route(destination, (route) =>
        route.fulfill({ contentType: 'text/html', body: '<p>Password update destination</p>' })
      );
      await submitButton.click();
      await expect
        .poll(() => requests)
        .toEqual([
          {
            method: 'PATCH',
            data: {
              current_password: 'password123',
              password: 'newpassword456',
              password_confirmation: 'newpassword456',
            },
          },
        ]);
      await expect(page).toHaveURL(destination);
      await expect(page.getByText('Password update destination')).toBeVisible();
    });

    test('should show user email on password page', async ({ mount }) => {
      const props = {
        user: {
          id: 1,
          email_address: 'specific@email.com',
          first_name: 'Specific',
          last_name: 'User',
        },
      };

      const component = await mount(UserEditPasswordPage, { props });

      await expect(component.getByLabel('Email', { exact: true })).toHaveValue('specific@email.com');
      await expect(component.getByLabel('Email', { exact: true })).toBeDisabled();
    });
  });
});
