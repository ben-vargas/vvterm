import React from "react";
import { ThanksPage } from "../pages";
import "../index.css";
import { mountApp } from "../mountApp";

function start() {
  mountApp(<ThanksPage />);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
