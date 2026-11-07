import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ImageResponse } from "next/og";
import { fullAddress, siteConfig } from "@/config/site";

/**
 * La imagen que se ve cuando alguien comparte el link por WhatsApp,
 * Facebook o Messenger.
 *
 * No es una foto: se arma con el emblema, el nombre y los datos reales
 * del gimnasio, así nunca muestra algo que no corresponde.
 */
export const alt = `${siteConfig.name} — ${siteConfig.address.city}`;
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

// Se genera una sola vez al compilar, no en cada visita.
export const dynamic = "force-static";

export default function Image() {
  const anton = readFileSync(join(process.cwd(), "src/app/_og/anton.woff"));

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          background: "#0c0c0e",
          backgroundImage:
            "radial-gradient(900px 500px at 88% 8%, #8f0f15 0%, rgba(143,15,21,0) 60%)",
          padding: "72px 80px",
          fontFamily: "Anton",
        }}
      >
        {/* Emblema + nombre */}
        <div style={{ display: "flex", alignItems: "center", gap: 28 }}>
          <svg width="104" height="104" viewBox="0 0 100 100">
            <rect x="26" y="16" width="48" height="50" rx="24" fill="#d81a22" />
            <ellipse cx="22" cy="50" rx="10" ry="13" fill="#d81a22" />
            <rect x="40" y="70" width="26" height="14" rx="6" fill="#d81a22" />
            <path
              d="M36 38 C29 46 29 56 36 64"
              stroke="#0c0c0e"
              strokeWidth="4"
              strokeLinecap="round"
              fill="none"
            />
            <path
              d="M44 72 h18"
              stroke="#0c0c0e"
              strokeWidth="3"
              strokeLinecap="round"
            />
          </svg>

          <div style={{ display: "flex", flexDirection: "column" }}>
            <span
              style={{
                fontFamily: "Anton",
                fontSize: 52,
                color: "#ffffff",
                letterSpacing: "0.01em",
                lineHeight: 1,
              }}
            >
              POWER BOX
            </span>
            <span
              style={{
                fontSize: 20,
                color: "rgba(255,255,255,0.6)",
                letterSpacing: "0.3em",
                marginTop: 8,
              }}
            >
              GYM
            </span>
          </div>
        </div>

        {/* Mensaje principal */}
        <div style={{ display: "flex", flexDirection: "column", marginTop: 8 }}>
          <span
            style={{
              fontFamily: "Anton",
              fontSize: 104,
              color: "#ffffff",
              lineHeight: 0.92,
              letterSpacing: "-0.01em",
            }}
          >
            ENTRENÁ FUERTE
          </span>
          <span
            style={{
              fontFamily: "Anton",
              fontSize: 104,
              color: "#d81a22",
              lineHeight: 0.92,
              letterSpacing: "-0.01em",
            }}
          >
            AQUÍ CERCA
          </span>
          <span
            style={{
              fontSize: 26,
              color: "rgba(255,255,255,0.72)",
              marginTop: 26,
              maxWidth: 820,
              lineHeight: 1.4,
            }}
          >
            Máquinas modernas, boxeo para todas las edades, zumba y suplementos.
          </span>
        </div>

        {/* Datos reales */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 20,
            borderTop: "1px solid rgba(255,255,255,0.14)",
            paddingTop: 28,
          }}
        >
          <span style={{ fontSize: 22, color: "#ffffff", fontWeight: 600 }}>
            {siteConfig.phoneIntl}
          </span>
          <span style={{ fontSize: 22, color: "rgba(255,255,255,0.35)" }}>·</span>
          <span style={{ fontSize: 22, color: "rgba(255,255,255,0.68)" }}>{fullAddress()}</span>
        </div>
      </div>
    ),
    {
      ...size,
      fonts: [{ name: "Anton", data: anton, style: "normal", weight: 400 }],
    },
  );
}
