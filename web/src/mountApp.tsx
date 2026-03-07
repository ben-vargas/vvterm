import React from "react";
import { createRoot, hydrateRoot } from "react-dom/client";

export function mountApp(node: React.ReactNode) {
  const container = document.getElementById("root");

  if (!container) {
    throw new Error("Expected #root container to exist");
  }

  if (container.hasChildNodes()) {
    hydrateRoot(container, node);
    return;
  }

  createRoot(container).render(node);
}
