import React from "react";
import { TermsPage } from "../pages";
import "../index.css";
import { mountApp } from "../mountApp";

function start() {
  mountApp(<TermsPage />);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
