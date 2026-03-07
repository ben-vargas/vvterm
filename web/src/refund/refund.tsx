import React from "react";
import { RefundPage } from "../pages";
import "../index.css";
import { mountApp } from "../mountApp";

function start() {
  mountApp(<RefundPage />);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
