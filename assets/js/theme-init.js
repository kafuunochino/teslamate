import { initializeTheme } from "./theme.mjs";

// This small entry runs before the stylesheet so the first paint uses the
// device preference or the choice previously saved in this browser.
initializeTheme(window, document);
