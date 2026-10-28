// Doctor PC — FPS del juego con PresentMon (Intel, licencia MIT: https://github.com/GameTechDev/PresentMon).
// PresentMon lee los eventos de presentación de fotogramas de Windows (ETW). Necesita ejecutarse como
// administrador o que el usuario pertenezca al grupo "Usuarios del registro de rendimiento" (S-1-5-32-559).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

internal sealed class MedidorFps
{
    private const string Sesion = "DoctorPC_FPS";
    private const int MaxFotogramas = 3000;

    private struct Fotograma
    {
        public long Llegada;      // ms del reloj interno al recibir la línea
        public double Ms;         // tiempo entre presentaciones
        public string Cadena;     // swap chain
    }

    private readonly string ruta;
    private readonly object bloqueo = new object();
    private readonly List<Fotograma> fotogramas = new List<Fotograma>();
    private readonly Stopwatch reloj = Stopwatch.StartNew();
    private Process proc;
    private int pid;
    private int colMs = -1, colCadena = -1, colPid = -1;
    private string estado = "inactivo";
    private string detalle;
    private long inicio;

    public MedidorFps(string rutaPresentMon) { ruta = rutaPresentMon; }

    public bool Disponible => File.Exists(ruta);

    // Cambia el proceso que se mide (0 = ninguno)
    public void Objetivo(int nuevo)
    {
        if (nuevo == pid)
        {
            if (nuevo == 0 || estado == "permiso" || estado == "sin-presentmon") return;
            if (proc != null && !Termino(proc)) return;
            if (reloj.ElapsedMilliseconds - inicio < 10000) return;   // no reintentar en bucle
        }
        Parar();
        pid = nuevo;
        if (pid <= 0) { estado = "inactivo"; return; }
        if (!Disponible) { estado = "sin-presentmon"; return; }
        Iniciar();
    }

    private static bool Termino(Process p)
    {
        try { return p.HasExited; } catch { return true; }
    }

    private void Iniciar()
    {
        lock (bloqueo) { fotogramas.Clear(); colMs = colCadena = colPid = -1; }
        estado = "iniciando"; detalle = null; inicio = reloj.ElapsedMilliseconds;
        var psi = new ProcessStartInfo(ruta,
            "--process_id " + pid.ToString(CultureInfo.InvariantCulture) +
            " --output_stdout --no_console_stats --session_name " + Sesion +
            " --stop_existing_session --no_track_gpu --no_track_input")
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.ASCII, StandardErrorEncoding = Encoding.ASCII
        };
        try
        {
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            p.OutputDataReceived += (s, e) => { if (e.Data != null) Linea(e.Data); };
            var errores = new StringBuilder();
            p.ErrorDataReceived += (s, e) =>
            {
                if (e.Data == null) return;
                lock (errores) errores.AppendLine(e.Data);
                string l = e.Data.ToLowerInvariant();
                if (l.Contains("access denied") || l.Contains("performance log users")) estado = "permiso";
                else if (l.StartsWith("error")) { if (estado != "permiso") estado = "error"; detalle = e.Data.Trim(); }
            };
            p.Exited += (s, e) =>
            {
                if (estado == "midiendo" || estado == "iniciando") { estado = "terminado"; }
            };
            p.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            proc = p;
        }
        catch (Exception e)
        {
            estado = "error"; detalle = e.Message; proc = null;
        }
    }

    public void Parar()
    {
        Process p = proc;
        proc = null;
        if (p == null) return;
        try { if (!p.HasExited) p.Kill(); } catch { }
        try { p.Dispose(); } catch { }
        // PresentMon terminado a la fuerza deja abierta la sesión de rastreo: se cierra aparte
        try
        {
            var psi = new ProcessStartInfo(ruta, "--terminate_existing_session --session_name " + Sesion)
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            using (var t = Process.Start(psi)) { t.WaitForExit(3000); }
        }
        catch { }
    }

    private void Linea(string l)
    {
        if (l.Length == 0) return;
        if (colMs < 0)
        {
            if (!l.StartsWith("Application", StringComparison.OrdinalIgnoreCase)) return;
            Cabecera(l);
            return;
        }
        Fotograma f;
        if (!Analizar(l, colMs, colCadena, colPid, pid, out f)) return;
        f.Llegada = reloj.ElapsedMilliseconds;
        lock (bloqueo)
        {
            fotogramas.Add(f);
            if (fotogramas.Count > MaxFotogramas) fotogramas.RemoveRange(0, fotogramas.Count - MaxFotogramas);
        }
        estado = "midiendo";
    }

    private void Cabecera(string l)
    {
        string[] c = l.Split(',');
        for (int i = 0; i < c.Length; i++)
        {
            string n = c[i].Trim();
            if (n.Equals("MsBetweenPresents", StringComparison.OrdinalIgnoreCase)) colMs = i;
            else if (n.Equals("SwapChainAddress", StringComparison.OrdinalIgnoreCase)) colCadena = i;
            else if (n.Equals("ProcessID", StringComparison.OrdinalIgnoreCase)) colPid = i;
        }
        if (colMs < 0) { estado = "error"; detalle = "Formato de PresentMon desconocido"; }
    }

    private static bool Analizar(string l, int colMs, int colCadena, int colPid, int pidEsperado, out Fotograma f)
    {
        f = default(Fotograma);
        string[] c = l.Split(',');
        if (c.Length <= colMs) return false;
        if (colPid >= 0 && pidEsperado > 0 && c.Length > colPid)
        {
            int p;
            if (int.TryParse(c[colPid], NumberStyles.Integer, CultureInfo.InvariantCulture, out p) && p != pidEsperado) return false;
        }
        double ms;
        if (!double.TryParse(c[colMs], NumberStyles.Float, CultureInfo.InvariantCulture, out ms)) return false;
        if (ms <= 0.05 || ms > 5000) return false;
        f.Ms = ms;
        f.Cadena = colCadena >= 0 && c.Length > colCadena ? c[colCadena] : "";
        return true;
    }

    // Calcula FPS medios (último segundo), 1 % bajo y tiempo de fotograma a partir de una lista
    private static void Calcular(List<Fotograma> lista, long ahora, out double? fps, out double? bajo1, out double? msMedio, out int n)
    {
        fps = bajo1 = msMedio = null; n = 0;
        if (lista.Count == 0) return;
        // la swap chain principal: la que más fotogramas presentó en los últimos 3 s
        var recientes = lista.Where(f => ahora - f.Llegada <= 3000).ToList();
        if (recientes.Count == 0) return;
        string principal = recientes.GroupBy(f => f.Cadena).OrderByDescending(g => g.Count()).First().Key;
        var cadena = lista.Where(f => f.Cadena == principal).ToList();
        // FPS: fotogramas llegados en el último segundo (al menos 1,5 s si va muy lento)
        var ventana = cadena.Where(f => ahora - f.Llegada <= 1000).ToList();
        if (ventana.Count < 2) ventana = cadena.Where(f => ahora - f.Llegada <= 1500).ToList();
        if (ventana.Count == 0) return;
        double suma = ventana.Sum(f => f.Ms);
        if (suma <= 0) return;
        fps = ventana.Count * 1000.0 / suma;
        msMedio = suma / ventana.Count;
        n = ventana.Count;
        // 1 % bajo: el percentil 99 del tiempo de fotograma de los últimos 1000 fotogramas
        var ultimos = cadena.Skip(Math.Max(0, cadena.Count - 1000)).Select(f => f.Ms).OrderBy(x => x).ToList();
        if (ultimos.Count >= 20)
        {
            double p99 = ultimos[(int)Math.Min(ultimos.Count - 1, Math.Ceiling(ultimos.Count * 0.99) - 1)];
            if (p99 > 0) bajo1 = 1000.0 / p99;
        }
    }

    public string Json()
    {
        double? fps = null, bajo = null, ms = null; int n = 0;
        if (pid > 0 && estado == "midiendo")
        {
            lock (bloqueo) Calcular(fotogramas, reloj.ElapsedMilliseconds, out fps, out bajo, out ms, out n);
        }
        // si el juego dejó de presentar fotogramas (pausado, minimizado) no se muestran FPS viejos
        var sb = new StringBuilder(160);
        sb.Append("{\"pid\":").Append(pid)
          .Append(",\"estado\":\"").Append(estado).Append('"')
          .Append(",\"v\":").Append(N(fps))
          .Append(",\"bajo1\":").Append(N(bajo))
          .Append(",\"ms\":").Append(N(ms))
          .Append(",\"n\":").Append(n);
        if (detalle != null) sb.Append(",\"detalle\":\"").Append(detalle.Replace("\\", "/").Replace("\"", "'")).Append('"');
        return sb.Append('}').ToString();
    }

    private static string N(double? v) => v.HasValue ? Math.Round(v.Value, 1).ToString(CultureInfo.InvariantCulture) : "null";

    // Prueba sin PresentMon: lee un CSV con el formato de PresentMon y devuelve FPS, 1 % bajo y ms.
    // Todas las filas se consideran llegadas en el mismo instante.
    public static string ProbarCsv(string archivo)
    {
        int cMs = -1, cCad = -1, cPid = -1;
        var lista = new List<Fotograma>();
        foreach (string l in File.ReadLines(archivo))
        {
            if (cMs < 0)
            {
                if (!l.StartsWith("Application", StringComparison.OrdinalIgnoreCase)) continue;
                string[] c = l.Split(',');
                for (int i = 0; i < c.Length; i++)
                {
                    string n = c[i].Trim();
                    if (n.Equals("MsBetweenPresents", StringComparison.OrdinalIgnoreCase)) cMs = i;
                    else if (n.Equals("SwapChainAddress", StringComparison.OrdinalIgnoreCase)) cCad = i;
                    else if (n.Equals("ProcessID", StringComparison.OrdinalIgnoreCase)) cPid = i;
                }
                continue;
            }
            Fotograma f;
            if (Analizar(l, cMs, cCad, cPid, 0, out f)) { f.Llegada = 1000; lista.Add(f); }
        }
        // para la prueba, la ventana de 1 s son los fotogramas cuya suma de tiempos cabe en el último segundo
        double acum = 0; int desde = lista.Count;
        for (int i = lista.Count - 1; i >= 0; i--) { acum += lista[i].Ms; if (acum > 1000) break; desde = i; }
        for (int i = 0; i < lista.Count; i++) { var f = lista[i]; f.Llegada = i >= desde ? 1000 : -5000; lista[i] = f; }
        double? fps, bajo, ms; int cuenta;
        Calcular(lista, 1000, out fps, out bajo, out ms, out cuenta);
        return "{\"fps\":" + N(fps) + ",\"bajo1\":" + N(bajo) + ",\"ms\":" + N(ms) + ",\"n\":" + cuenta + ",\"total\":" + lista.Count + "}";
    }
}
