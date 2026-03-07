import React from "react";
import { renderToString } from "react-dom/server";
import { App } from "./src/App";
import { PrivacyPage, RefundPage, SupportPage, TermsPage, ThanksPage } from "./src/pages";

const ROOT_CONTAINER_PATTERN = /<div id="root"><\/div>/;
const LEADING_PRELOADS_PATTERN = /^(?:<link rel="preload"[^>]*\/>)+/;

const pages: Record<string, React.ReactElement> = {
  "/": <App />,
  "/privacy": <PrivacyPage />,
  "/refund": <RefundPage />,
  "/support": <SupportPage />,
  "/terms": <TermsPage />,
  "/thanks": <ThanksPage />,
};

export function prerenderHtml(route: string, html: string): string {
  const page = pages[route];

  if (!page || !ROOT_CONTAINER_PATTERN.test(html)) {
    return html;
  }

  const markup = renderToString(page).replace(LEADING_PRELOADS_PATTERN, "");
  return html.replace(ROOT_CONTAINER_PATTERN, `<div id="root">${markup}</div>`);
}
