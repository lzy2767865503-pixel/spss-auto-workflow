import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const apiPort = process.env.SPSS_AUTO_PORT || "8765";
const apiTarget =
  process.env.VITE_API_PROXY_TARGET || `http://127.0.0.1:${apiPort}`;

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      "/api": apiTarget,
    },
  },
});
