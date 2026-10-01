// Route helpers for component testing
// These return the actual Rails route paths
export const rootPath = () => '/';
export const loginPath = () => '/login';
export const signupPath = () => '/signup';
export const logoutPath = () => '/logout';
export const newPasswordPath = () => '/passwords/new';
export const passwordPath = () => '/password';
export const passwordsPath = () => '/passwords';

export default {
  rootPath,
  loginPath,
  signupPath,
  logoutPath,
  newPasswordPath,
  passwordPath,
  passwordsPath,
};
export { accountChatMessagesPath } from '../app/frontend/routes';
