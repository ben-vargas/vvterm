import React from "react";
import { App } from "./App";
import "./index.css";
import { mountApp } from "./mountApp";

function start() {
  mountApp(<App />);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
