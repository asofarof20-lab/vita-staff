
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  const reply = (data: unknown, status = 200) =>
    new Response(JSON.stringify(data), {
      status,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json",
      },
    });

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return reply({ error: "Метод не поддерживается" }, 405);
  }

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const rawKeys = Deno.env.get("SUPABASE_SECRET_KEYS");

    let secretKey =
      Deno.env.get("SUPABASE_SECRET_KEY") ||
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (rawKeys) {
      try {
        const keys = JSON.parse(rawKeys);
        secretKey = keys.default || secretKey;
      } catch {
        if (rawKeys.startsWith("sb_secret_")) {
          secretKey = rawKeys;
        }
      }
    }

    if (!url || !secretKey) {
      return reply(
        { error: "Не найден URL или Secret Key" },
        500,
      );
    }

    const token = (req.headers.get("Authorization") || "")
      .replace(/^Bearer\s+/i, "")
      .trim();

    if (!token) {
      return reply(
        { error: "Токен входа не передан" },
        401,
      );
    }

    const adminClient = createClient(url, secretKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    });

    const { data: userData, error: userError } =
      await adminClient.auth.getUser(token);

    if (userError || !userData.user) {
      return reply(
        {
          error: "Не удалось проверить пользователя",
          details: userError?.message,
        },
        401,
      );
    }

    const { data: staff, error: staffError } =
      await adminClient
        .from("vita_staff")
        .select("role, active")
        .eq("user_id", userData.user.id)
        .maybeSingle();

    if (staffError) {
      return reply(
        {
          error: "Ошибка проверки администратора",
          details: staffError.message,
        },
        500,
      );
    }

    if (
      staff?.role !== "admin" ||
      staff?.active !== true
    ) {
      return reply(
        {
          error:
            "Только активный администратор может создавать сотрудников",
        },
        403,
      );
    }

    const body = await req.json();

    const email = String(body.email ?? "").trim();
    const password = String(body.password ?? "");
    const full_name = String(body.full_name ?? "").trim();
    const username = String(body.username ?? "").trim();
    const role = String(body.role ?? "").trim();
    const zone_id = role === "sales"
      ? String(body.zone_id ?? "").trim()
      : null;

    // Разрешённые должности, включая бухгалтера
    const allowedRoles = [
      "sales",
      "delivery",
      "accountant",
    ];

    if (
      !email ||
      !password ||
      !full_name ||
      !username ||
      !allowedRoles.includes(role)
    ) {
      return reply(
        {
          error:
            "Заполните все поля и выберите должность",
        },
        400,
      );
    }

    if (password.length < 6) {
      return reply(
        {
          error:
            "Пароль должен содержать минимум 6 символов",
        },
        400,
      );
    }

    if (role === "sales") {
      if (!zone_id) {
        return reply({ error: "Для торгового представителя обязательно выберите зону" }, 400);
      }
      const { data: zone, error: zoneError } = await adminClient
        .from("vita_zones")
        .select("id")
        .eq("id", zone_id)
        .eq("active", true)
        .maybeSingle();
      if (zoneError || !zone) {
        return reply({ error: "Выбранная зона не найдена или неактивна" }, 400);
      }
    }

    const { data: newUser, error: createError } =
      await adminClient.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
      });

    if (createError || !newUser.user) {
      return reply(
        {
          error:
            createError?.message ||
            "Не удалось создать аккаунт",
        },
        400,
      );
    }

    const { error: insertError } =
      await adminClient
        .from("vita_staff")
        .insert({
          user_id: newUser.user.id,
          full_name,
          username,
          role,
          zone_id,
          active: true,
        });

    if (insertError) {
      // Удаляем созданный аккаунт,
      // если запись сотрудника не сохранилась
      const { error: deleteError } =
        await adminClient.auth.admin.deleteUser(
          newUser.user.id,
        );

      console.error(
        "Ошибка сохранения сотрудника:",
        insertError,
      );

      if (deleteError) {
        console.error(
          "Ошибка удаления аккаунта:",
          deleteError,
        );
      }

      return reply(
        {
          error: insertError.message,
          details: deleteError
            ? "Не удалось удалить созданный аккаунт: " +
              deleteError.message
            : undefined,
        },
        400,
      );
    }

    return reply({
      success: true,
      message: "Сотрудник успешно создан",
      user_id: newUser.user.id,
      role,
    });
  } catch (error) {
    console.error("Ошибка функции:", error);

    return reply(
      {
        error:
          error instanceof Error
            ? error.message
            : String(error),
      },
      500,
    );
  }
});
