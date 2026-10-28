// Doctor PC — lector de sensores.
// Escribe una línea JSON por lectura con temperaturas, cargas, relojes, potencia y ventiladores de CPU y GPU.
//
//   DoctorPC.Sensores.exe [--intervalo ms] [--muestras n] [--padre pid] [--salida archivo] [--control archivo]
//
//   --muestras 0     lee sin parar (por defecto) hasta que termine el proceso --padre
//   --salida         añade las líneas a un archivo (necesario cuando se ejecuta como administrador)
//   --control        archivo con el intervalo en ms (o "salir"), se relee en cada vuelta
//
// La temperatura de la GPU (AMD, NVIDIA, Intel) no necesita permisos especiales.
// La del procesador necesita el controlador PawnIO instalado y ejecutar como administrador.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Text;
using System.Threading;
using LibreHardwareMonitor.Hardware;
using Microsoft.Win32;

internal static class Programa
{
    private static int Main(string[] args)
    {
        int intervalo = 1000, muestras = 0, padre = 0;
        string salida = null, control = null;
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            string sig = i + 1 < args.Length ? args[i + 1] : null;
            switch (a)
            {
                case "--intervalo": intervalo = Entero(sig, 1000); i++; break;
                case "--muestras": muestras = Entero(sig, 0); i++; break;
                case "--padre": padre = Entero(sig, 0); i++; break;
                case "--salida": salida = sig; i++; break;
                case "--control": control = sig; i++; break;
            }
        }
        Thread.CurrentThread.CurrentCulture = CultureInfo.InvariantCulture;
        bool admin = EsAdmin();
        bool pawnio = HayPawnIO();

        StreamWriter archivo = null;
        if (!string.IsNullOrEmpty(salida))
        {
            archivo = new StreamWriter(new FileStream(salida, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
            archivo.AutoFlush = true;
        }
        Action<string> escribir = linea =>
        {
            if (archivo != null) archivo.WriteLine(linea);
            else { Console.Out.WriteLine(linea); Console.Out.Flush(); }
        };

        var pc = new Computer { IsCpuEnabled = true, IsGpuEnabled = true, IsMotherboardEnabled = true };
        try
        {
            pc.Open();
        }
        catch (Exception e)
        {
            escribir("{\"error\":" + Json(e.Message) + ",\"admin\":" + Bool(admin) + ",\"pawnio\":" + Bool(pawnio) + "}");
            if (archivo != null) archivo.Dispose();
            return 1;
        }

        try
        {
            for (int t = 0; muestras == 0 || t < muestras; t++)
            {
                if (padre > 0 && !Vivo(padre)) break;
                if (control != null && !LeerControl(control, ref intervalo)) break;
                var reloj = Stopwatch.StartNew();
                foreach (IHardware h in pc.Hardware)
                {
                    try { Actualizar(h); } catch { /* un sensor que falla no detiene la lectura */ }
                }
                string linea;
                try { linea = Muestra(pc, t, admin, pawnio); }
                catch (Exception e) { linea = "{\"t\":" + t + ",\"error\":" + Json(e.Message) + "}"; }
                escribir(linea);
                int resto = intervalo - (int)reloj.ElapsedMilliseconds;
                if (resto > 20 && (muestras == 0 || t + 1 < muestras)) Thread.Sleep(resto);
            }
        }
        finally
        {
            if (archivo != null) archivo.Dispose();
            try { pc.Close(); } catch { }
        }
        return 0;
    }

    private static void Actualizar(IHardware h)
    {
        h.Update();
        foreach (IHardware sub in h.SubHardware) Actualizar(sub);
    }

    private static List<ISensor> Sensores(IHardware h)
    {
        var lista = new List<ISensor>(h.Sensors);
        foreach (IHardware sub in h.SubHardware) lista.AddRange(Sensores(sub));
        return lista;
    }

    private static bool Valido(float v, SensorType tipo)
    {
        if (float.IsNaN(v) || float.IsInfinity(v)) return false;
        if (tipo == SensorType.Temperature) return v > 5 && v < 125;
        return v >= 0;
    }

    private static float? Buscar(List<ISensor> ss, SensorType tipo, params string[] nombres)
    {
        foreach (string n in nombres)
            foreach (ISensor s in ss)
                if (s.SensorType == tipo && s.Value.HasValue && string.Equals(s.Name, n, StringComparison.OrdinalIgnoreCase) && Valido(s.Value.Value, tipo))
                    return s.Value.Value;
        return null;
    }

    private static float? Maximo(List<ISensor> ss, SensorType tipo, Func<string, bool> filtro)
    {
        float? m = null;
        foreach (ISensor s in ss)
            if (s.SensorType == tipo && s.Value.HasValue && filtro(s.Name) && Valido(s.Value.Value, tipo))
                m = m.HasValue ? Math.Max(m.Value, s.Value.Value) : s.Value.Value;
        return m;
    }

    private static string Muestra(Computer pc, int t, bool admin, bool pawnio)
    {
        var sb = new StringBuilder(512);
        sb.Append("{\"t\":").Append(t).Append(",\"admin\":").Append(Bool(admin)).Append(",\"pawnio\":").Append(Bool(pawnio));

        IHardware cpu = pc.Hardware.FirstOrDefault(h => h.HardwareType == HardwareType.Cpu);
        if (cpu != null)
        {
            var ss = Sensores(cpu);
            float? temp = Buscar(ss, SensorType.Temperature, "CPU Package", "Core (Tctl/Tdie)", "Core (Tctl)", "Core (Tdie)", "Package", "Core Max", "CPU Cores", "Core Average");
            if (!temp.HasValue) temp = Maximo(ss, SensorType.Temperature, n => n.StartsWith("Core", StringComparison.OrdinalIgnoreCase) || n.StartsWith("CCD", StringComparison.OrdinalIgnoreCase));
            float? carga = Buscar(ss, SensorType.Load, "CPU Total");
            float? potencia = Buscar(ss, SensorType.Power, "CPU Package", "Package");
            float? reloj = Maximo(ss, SensorType.Clock, n => n.IndexOf("Core", StringComparison.OrdinalIgnoreCase) >= 0 && n.IndexOf("Bus", StringComparison.OrdinalIgnoreCase) < 0);
            sb.Append(",\"cpu\":{\"nombre\":").Append(Json(cpu.Name))
              .Append(",\"temp\":").Append(Num(temp))
              .Append(",\"carga\":").Append(Num(carga))
              .Append(",\"potencia\":").Append(Num(potencia))
              .Append(",\"reloj\":").Append(Num(reloj)).Append('}');
        }

        sb.Append(",\"gpus\":[");
        bool primera = true;
        foreach (IHardware g in pc.Hardware)
        {
            if (g.HardwareType != HardwareType.GpuAmd && g.HardwareType != HardwareType.GpuNvidia && g.HardwareType != HardwareType.GpuIntel) continue;
            var ss = Sensores(g);
            if (!primera) sb.Append(',');
            primera = false;
            sb.Append("{\"nombre\":").Append(Json(g.Name))
              .Append(",\"tipo\":").Append(Json(g.HardwareType.ToString()))
              .Append(",\"temp\":").Append(Num(Buscar(ss, SensorType.Temperature, "GPU Core", "GPU Temperature", "GPU")))
              .Append(",\"hotspot\":").Append(Num(Buscar(ss, SensorType.Temperature, "GPU Hot Spot", "GPU Hotspot", "GPU Junction")))
              .Append(",\"memTemp\":").Append(Num(Buscar(ss, SensorType.Temperature, "GPU Memory Junction", "GPU Memory")))
              .Append(",\"carga\":").Append(Num(Buscar(ss, SensorType.Load, "GPU Core", "D3D 3D")))
              .Append(",\"reloj\":").Append(Num(Buscar(ss, SensorType.Clock, "GPU Core")))
              .Append(",\"vramUsadaMB\":").Append(Num(Buscar(ss, SensorType.SmallData, "GPU Memory Used", "D3D Dedicated Memory Used")))
              .Append(",\"vramTotalMB\":").Append(Num(Buscar(ss, SensorType.SmallData, "GPU Memory Total", "D3D Dedicated Memory Total")))
              .Append(",\"potencia\":").Append(Num(Buscar(ss, SensorType.Power, "GPU Package", "GPU Power", "GPU Core", "GPU Total")))
              .Append(",\"ventRpm\":").Append(Num(Maximo(ss, SensorType.Fan, n => true)))
              .Append(",\"ventPct\":").Append(Num(Maximo(ss, SensorType.Control, n => n.IndexOf("Fan", StringComparison.OrdinalIgnoreCase) >= 0)))
              .Append('}');
        }
        sb.Append(']');

        sb.Append(",\"ventiladores\":[");
        primera = true;
        foreach (IHardware placa in pc.Hardware.Where(h => h.HardwareType == HardwareType.Motherboard))
        {
            foreach (ISensor s in Sensores(placa))
            {
                if (s.SensorType != SensorType.Fan || !s.Value.HasValue || s.Value.Value < 1) continue;
                if (!primera) sb.Append(',');
                primera = false;
                sb.Append("{\"nombre\":").Append(Json(s.Name)).Append(",\"rpm\":").Append(Num(s.Value)).Append('}');
            }
        }
        sb.Append("]}");
        return sb.ToString();
    }

    private static string Num(float? v) => v.HasValue ? Math.Round(v.Value, 1).ToString(CultureInfo.InvariantCulture) : "null";
    private static string Bool(bool b) => b ? "true" : "false";

    private static string Json(string s)
    {
        if (s == null) return "null";
        var sb = new StringBuilder(s.Length + 2).Append('"');
        foreach (char c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.Append('"').ToString();
    }

    private static int Entero(string s, int def)
    {
        int v;
        return int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out v) ? v : def;
    }

    private static bool EsAdmin()
    {
        try
        {
            using (WindowsIdentity id = WindowsIdentity.GetCurrent())
                return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    }

    private static bool HayPawnIO()
    {
        try
        {
            using (RegistryKey k = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\PawnIO"))
                return k != null;
        }
        catch { return false; }
    }

    private static bool Vivo(int pid)
    {
        try { return !Process.GetProcessById(pid).HasExited; }
        catch (ArgumentException) { return false; }
        catch { return true; }
    }

    // Devuelve false si hay que terminar
    private static bool LeerControl(string ruta, ref int intervalo)
    {
        try
        {
            if (!File.Exists(ruta)) return true;
            string s = File.ReadAllText(ruta).Trim();
            if (s == "salir") return false;
            int v;
            if (int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out v) && v >= 250 && v <= 10000) intervalo = v;
        }
        catch { }
        return true;
    }
}
