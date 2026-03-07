import React from "react";
import { SupportPage } from "../pages";
import "../index.css";
import { mountApp } from "../mountApp";

function start() {
  mountApp(<SupportPage />);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
