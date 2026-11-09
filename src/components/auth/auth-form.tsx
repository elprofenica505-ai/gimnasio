"use client";

import { todayInManagua, validBirthDate } from "@/lib/age/birth-date";
import Link from "next/link";
import { validNewPassword, NEW_PASSWORD_MAX } from "@/lib/auth/password-recovery";
import { safeAuthRedirect } from "@/lib/auth/redirects";
import { isStaffRole } from "@/lib/auth/current-user";
import { getSupabaseBrowserClient } from "@/lib/supabase/client";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { AlertTriangle, ArrowRight, CheckCircle2, Eye, EyeOff, Loader2 } from "lucide-react";
import { useApp } from "@/components/providers/app-provider";
import { useDictionary } from "@/components/providers/dictionary-provider";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/field";

type Mode = "login" | "register";

/** Destino por defecto tras el login: el personal cae en su Panel
 * (con MFA ya verificado); el resto, en Mi cuenta. El redirect explícito
 * (deep-link a checkout, etc.) siempre gana sobre esto. */
async function destinoTrasLogin(locale: string): Promise<string> {
  const supabase = getSupabaseBrowserClient();
  if (!supabase) return `/${locale}/mi-cuenta`;
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return `/${locale}/mi-cuenta`;
  const [{ data: perfil }, { data: niveles }] = await Promise.all([
    supabase.from("profiles").select("role").eq("id", user.id).single(),
    supabase.auth.mfa.getAuthenticatorAssuranceLevel(),
  ]);
  return isStaffRole(perfil?.role) && niveles?.currentLevel === "aal2"
    ? `/${locale}/panel`
    : `/${locale}/mi-cuenta`;
}

export function AuthForm({ mode, redirectTo }: { mode: Mode; redirectTo?: string }) {
  const { dict, locale } = useDictionary();
  const { signIn, signUp, authLoading, isDemo } = useApp();
  const router = useRouter();

  const [showPassword, setShowPassword] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});
  const [confirmationEmail, setConfirmationEmail] = useState<string | null>(null);

  const isLogin = mode === "login";

  async function onSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (authLoading) return;

    const data = new FormData(event.currentTarget);
    const email = String(data.get("email") ?? "").trim();
    const password = String(data.get("password") ?? "");
    const fullName = String(data.get("fullName") ?? "").trim();
    const phone = String(data.get("phone") ?? "").trim();
    const confirm = String(data.get("confirmPassword") ?? "");

    const errors: Record<string, string> = {};
    if (!isLogin) {
      if (fullName.length < 2) errors.fullName = dict.auth.requiredField;
      if (!validBirthDate(String(data.get("birthDate") ?? ""))) errors.birthDate = dict.auth.birthDateInvalid;
      if (!data.get("acceptPrivacy") || !data.get("acceptTerms")) errors.legal = dict.auth.legalRequired;
      if (!validNewPassword(password)) errors.password = dict.auth.passwordMin;
      if (password !== confirm) errors.confirmPassword = dict.auth.passwordMismatch;
    } else if (password.length < 1) {
      errors.password = dict.auth.requiredField;
    }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) {
      errors.email = dict.contact.invalidEmail;
    }

    setFieldErrors(errors);
    setError(null);
    if (Object.keys(errors).length > 0) return;

    const result = isLogin
      ? await signIn(email, password)
      : await signUp({
          fullName,
          email,
          password,
          phone,
          birthDate: String(data.get("birthDate") ?? ""),
          legalAccepted: Boolean(data.get("acceptPrivacy")) && Boolean(data.get("acceptTerms")),
        });

    if (!result.ok) {
      const message = (dict.auth as Record<string, unknown>)[result.error ?? "genericError"];
      setError(typeof message === "string" ? message : dict.auth.genericError);
      return;
    }

    if ("needsConfirmation" in result && result.needsConfirmation) {
      setConfirmationEmail(email);
      return;
    }

    // Login/registro exitoso: el personal va a su Panel, el resto a Mi
    // cuenta — salvo que venga de un deep-link explícito.
    const target = safeAuthRedirect(redirectTo, locale) || (await destinoTrasLogin(locale));
    router.replace(target);
    router.refresh();
  }

  /* ---------- Pantalla de "revisá tu correo" ---------- */
  if (confirmationEmail) {
    return (
      <div className="flex flex-col items-center gap-4 rounded-2xl border border-brand/35 bg-brand/[0.06] p-8 text-center">
        <span className="grid size-14 place-items-center rounded-full bg-brand text-onbrand">
          <CheckCircle2 className="size-7" aria-hidden="true" />
        </span>

        <h2 className="display-xl text-[1.5rem] leading-none">{dict.auth.confirmEmailTitle}</h2>

        <p className="max-w-sm text-[0.875rem] leading-relaxed text-mist">
          {dict.auth.confirmEmailText.replace("{email}", confirmationEmail)}
        </p>

        <Link
          href={`/${locale}/ingresar`}
          className="text-[0.8125rem] font-semibold text-brand-300 transition-opacity hover:opacity-80"
        >
          {dict.auth.goLogin}
        </Link>
      </div>
    );
  }

  if (isDemo) return (
    <p role="status" className="rounded-xl border border-line bg-card p-6 text-fog">
      {locale === "en"
        ? "Read-only demonstration. Login and registration are disabled. Do not enter personal information."
        : "Demostración de sólo lectura. Ingreso y registro deshabilitados. No ingresés datos personales."}
    </p>
  );

  return (
    <form
      onSubmit={onSubmit}
      noValidate
      className="flex flex-col gap-4 rounded-2xl border border-line bg-card p-6 sm:p-7"
    >
      {error ? (
        <div
          className="flex items-start gap-2.5 rounded-xl border border-alert/40 bg-alert/10 px-4 py-3"
          role="alert"
        >
          <AlertTriangle className="mt-0.5 size-4 shrink-0 text-alert" aria-hidden="true" />
          <p className="text-[0.8125rem] leading-snug text-alert">{error}</p>
        </div>
      ) : null}

      {!isLogin ? (
        <Input
          name="fullName"
          label={dict.auth.name}
          placeholder={dict.contact.namePlaceholder}
          autoComplete="name"
          required
          error={fieldErrors.fullName}
        />
      ) : null}

      <Input
        name="email"
        type="email"
        label={dict.auth.email}
        placeholder={dict.contact.emailPlaceholder}
        autoComplete="email"
        required
        error={fieldErrors.email}
      />

      {!isLogin ? (
        <Input
          name="birthDate"
          type="date"
          label={dict.auth.birthDate}
          hint={dict.auth.birthDateHint}
          autoComplete="bday"
          max={todayInManagua()}
          min="1920-01-01"
          required
          error={fieldErrors.birthDate}
        />
      ) : null}

      {!isLogin ? (
        <div className="grid gap-2 text-[0.8125rem] text-mist">
          <label className="flex items-start gap-2">
            <input name="acceptPrivacy" type="checkbox" className="mt-1" required />
            <span>
              {dict.auth.acceptPrivacy}{" "}
              <Link href={`/${locale}/privacidad`} target="_blank" className="underline">{dict.auth.readDocument}</Link>
            </span>
          </label>
          <label className="flex items-start gap-2">
            <input name="acceptTerms" type="checkbox" className="mt-1" required />
            <span>
              {dict.auth.acceptTerms}{" "}
              <Link href={`/${locale}/terminos`} target="_blank" className="underline">{dict.auth.readDocument}</Link>
            </span>
          </label>
          {fieldErrors.legal ? <p role="alert" className="text-alert">{fieldErrors.legal}</p> : null}
        </div>
      ) : null}

      {!isLogin ? (
        <Input
          name="phone"
          type="tel"
          label={dict.contact.phone}
          placeholder={dict.contact.phonePlaceholder}
          autoComplete="tel"
        />
      ) : null}

      <div className="relative">
        <Input
          name="password"
          type={showPassword ? "text" : "password"}
          label={dict.auth.password}
          hint={isLogin ? undefined : dict.auth.passwordHint}
          autoComplete={isLogin ? "current-password" : "new-password"}
          maxLength={isLogin ? undefined : NEW_PASSWORD_MAX}
          required
          error={fieldErrors.password}
        />

        <button
          type="button"
          onClick={() => setShowPassword((v) => !v)}
          aria-label={showPassword ? "Ocultar contraseña" : "Mostrar contraseña"}
          className="absolute top-9.5 right-3.5 text-fog transition-colors hover:text-ink"
        >
          {showPassword ? (
            <EyeOff className="size-4" aria-hidden="true" />
          ) : (
            <Eye className="size-4" aria-hidden="true" />
          )}
        </button>
      </div>

      {!isLogin ? (
        <Input
          name="confirmPassword"
          maxLength={NEW_PASSWORD_MAX}
          type={showPassword ? "text" : "password"}
          label={dict.auth.confirmPassword}
          autoComplete="new-password"
          required
          error={fieldErrors.confirmPassword}
        />
      ) : null}

      <Button type="submit" size="lg" disabled={authLoading} className="mt-2 w-full">
        {authLoading ? (
          <Loader2 className="size-4 animate-spin" aria-hidden="true" />
        ) : (
          <ArrowRight className="size-4" aria-hidden="true" />
        )}
        {authLoading ? dict.auth.loading : isLogin ? dict.auth.login : dict.auth.register}
      </Button>

      {isLogin ? <Link href={`/${locale}/recuperar`} className="text-sm text-brand-300 underline">{dict.recovery.forgot}</Link> : null}

      <p className="text-center text-[0.8125rem] text-fog">
        {isLogin ? dict.auth.noAccount : dict.auth.hasAccount}{" "}
        <Link
          href={`/${locale}/${isLogin ? "registro" : "ingresar"}`}
          className="font-semibold text-brand-300 transition-opacity hover:opacity-80"
        >
          {isLogin ? dict.auth.goRegister : dict.auth.goLogin}
        </Link>
      </p>
    </form>
  );
}
