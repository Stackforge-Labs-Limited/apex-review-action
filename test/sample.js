// A file for the self-test to review. Not part of the action.
export function login(user, password) {
  console.log("login", user, password);
  return fetch("http://api.example.com/login?pw=" + password);
}
