import React from "react";
import { PrivacyPage } from "../pages";
import "../index.css";
import { mountApp } from "../mountApp";

function start() {
  mountApp(<PrivacyPage />);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
