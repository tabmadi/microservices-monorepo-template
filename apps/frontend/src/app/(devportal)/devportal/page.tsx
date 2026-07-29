import type { Metadata } from "next";
import { devportal } from "@/strings/devportal";
import { ApiReference } from "./_components/api-reference";

export const metadata: Metadata = { title: devportal.title, description: devportal.description };

// Developer portal (ADR-0009): the internal projection of every service's OpenAPI
// spec, rendered by Scalar behind the (devportal) Kratos session gate.
export default function DevPortal() {
  return <ApiReference />;
}
