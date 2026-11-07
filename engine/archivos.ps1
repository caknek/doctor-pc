# Doctor PC — utilidades de archivos (se incluye desde los otros scripts con: . (Join-Path $PSScriptRoot 'archivos.ps1'))
# Clase DoctorPcFs en C#: mide, borra y analiza carpetas rápido y sin seguir enlaces (junctions/symlinks),
# así nunca sale de la carpeta indicada aunque dentro haya un enlace a otra parte del disco.
if (-not ('DoctorPcFs' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

// Recorre carpetas sin seguir enlaces (junctions/symlinks): nunca sale de la carpeta indicada.
public static class DoctorPcFs
{
    public class Resultado { public long Bytes; public long Archivos; public long Borrados; public long Liberado; public long Omitidos; }
    public class Grande { public string Ruta; public long Bytes; public DateTime Fecha; }
    public class Espacio
    {
        public long Total; public long Archivos; public long Inaccesibles;
        public Dictionary<string, long> Carpetas = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, long> Perfil = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        public List<Grande> Grandes = new List<Grande>();
    }

    static bool EsEnlace(FileSystemInfo i) { return (i.Attributes & FileAttributes.ReparsePoint) != 0; }

    static IEnumerable<FileInfo> Archivos(string raiz, string patron, bool recursivo, Resultado r)
    {
        var pila = new Stack<DirectoryInfo>();
        DirectoryInfo inicio;
        try { inicio = new DirectoryInfo(raiz); if (!inicio.Exists || EsEnlace(inicio)) yield break; } catch { yield break; }
        pila.Push(inicio);
        while (pila.Count > 0)
        {
            var d = pila.Pop();
            FileSystemInfo[] items;
            try { items = d.GetFileSystemInfos(); } catch { if (r != null) r.Omitidos++; continue; }
            foreach (var i in items)
            {
                if (i is DirectoryInfo)
                {
                    if (recursivo && !EsEnlace(i)) pila.Push((DirectoryInfo)i);
                    continue;
                }
                var f = i as FileInfo;
                if (f == null) continue;
                if (patron != null && patron != "*" && !Coincide(f.Name, patron)) continue;
                yield return f;
            }
        }
    }

    // Comodines simples: "*" y "?" (sin distinguir mayúsculas)
    public static bool Coincide(string nombre, string patron)
    {
        foreach (var p in patron.Split(';'))
        {
            string rx = "^" + System.Text.RegularExpressions.Regex.Escape(p.Trim()).Replace("\\*", ".*").Replace("\\?", ".") + "$";
            if (System.Text.RegularExpressions.Regex.IsMatch(nombre, rx, System.Text.RegularExpressions.RegexOptions.IgnoreCase)) return true;
        }
        return false;
    }

    public static Resultado Medir(string raiz, double minHoras, string patron, bool recursivo)
    {
        var r = new Resultado();
        DateTime limite = DateTime.UtcNow.AddHours(-minHoras);
        foreach (var f in Archivos(raiz, patron, recursivo, r))
        {
            try { if (minHoras > 0 && f.LastWriteTimeUtc > limite) continue; r.Bytes += f.Length; r.Archivos++; } catch { }
        }
        return r;
    }

    public static Resultado Borrar(string raiz, double minHoras, string patron, bool recursivo, bool quitarCarpetasVacias)
    {
        var r = new Resultado();
        DateTime limite = DateTime.UtcNow.AddHours(-minHoras);
        foreach (var f in Archivos(raiz, patron, recursivo, r).ToList())
        {
            long tam = 0;
            try
            {
                if (minHoras > 0 && f.LastWriteTimeUtc > limite) continue;
                tam = f.Length; r.Archivos++; r.Bytes += tam;
                if ((f.Attributes & FileAttributes.ReadOnly) != 0) f.Attributes = FileAttributes.Normal;
                f.Delete();
                r.Borrados++; r.Liberado += tam;
            }
            catch { r.Omitidos++; }
        }
        if (quitarCarpetasVacias) QuitarVacias(raiz, limite, minHoras > 0);
        return r;
    }

    // Quita subcarpetas vacías (nunca la carpeta raíz ni enlaces)
    static void QuitarVacias(string raiz, DateTime limite, bool usarLimite)
    {
        var todas = new List<DirectoryInfo>();
        var pila = new Stack<DirectoryInfo>();
        try { var ini = new DirectoryInfo(raiz); if (!ini.Exists || EsEnlace(ini)) return; pila.Push(ini); } catch { return; }
        while (pila.Count > 0)
        {
            var d = pila.Pop();
            DirectoryInfo[] subs;
            try { subs = d.GetDirectories(); } catch { continue; }
            foreach (var s in subs) { if (EsEnlace(s)) continue; todas.Add(s); pila.Push(s); }
        }
        foreach (var d in todas.OrderByDescending(x => x.FullName.Length))
        {
            try
            {
                d.Refresh();
                if (usarLimite && d.LastWriteTimeUtc > limite) continue;
                if (!d.EnumerateFileSystemInfos().Any()) d.Delete(false);
            }
            catch { }
        }
    }

    // Recorre una unidad o carpeta: tamaño por carpeta principal, por carpeta del perfil y los archivos más grandes
    public static Espacio Analizar(string raiz, string perfil, long minGrande, int maxGrandes, string progreso)
    {
        var e = new Espacio();
        var top = new List<Grande>();
        long minActual = minGrande;
        var pila = new Stack<KeyValuePair<DirectoryInfo, string[]>>();
        DirectoryInfo ini;
        try { ini = new DirectoryInfo(raiz); if (!ini.Exists) return e; } catch { return e; }
        string perfilN = string.IsNullOrEmpty(perfil) ? null : perfil.TrimEnd('\\') + "\\";
        pila.Push(new KeyValuePair<DirectoryInfo, string[]>(ini, new string[] { null, null }));
        var reloj = System.Diagnostics.Stopwatch.StartNew();
        long ultimo = 0;
        while (pila.Count > 0)
        {
            var par = pila.Pop();
            var d = par.Key; string carpeta = par.Value[0]; string sub = par.Value[1];
            FileSystemInfo[] items;
            try { items = d.GetFileSystemInfos(); } catch { e.Inaccesibles++; continue; }
            foreach (var i in items)
            {
                if (i is DirectoryInfo)
                {
                    if (EsEnlace(i)) continue;
                    string c = carpeta ?? i.Name;
                    string s = sub;
                    if (perfilN != null && s == null && (i.FullName + "\\").StartsWith(perfilN, StringComparison.OrdinalIgnoreCase) && i.FullName.Length > perfilN.Length)
                    {
                        string resto = i.FullName.Substring(perfilN.Length);
                        if (resto.IndexOf('\\') < 0) s = resto;
                    }
                    pila.Push(new KeyValuePair<DirectoryInfo, string[]>((DirectoryInfo)i, new string[] { c, s }));
                    continue;
                }
                var f = i as FileInfo;
                if (f == null) continue;
                long tam;
                try { tam = f.Length; } catch { continue; }
                e.Total += tam; e.Archivos++;
                string clave = carpeta ?? "(archivos sueltos en la raíz)";
                long v; e.Carpetas.TryGetValue(clave, out v); e.Carpetas[clave] = v + tam;
                if (sub != null) { e.Perfil.TryGetValue(sub, out v); e.Perfil[sub] = v + tam; }
                if (tam >= minActual)
                {
                    DateTime fecha = DateTime.MinValue;
                    try { fecha = f.LastWriteTime; } catch { }
                    top.Add(new Grande { Ruta = f.FullName, Bytes = tam, Fecha = fecha });
                    if (top.Count > maxGrandes * 2)
                    {
                        top = top.OrderByDescending(x => x.Bytes).Take(maxGrandes).ToList();
                        minActual = Math.Max(minGrande, top[top.Count - 1].Bytes);
                    }
                }
            }
            if (progreso != null && reloj.ElapsedMilliseconds - ultimo > 600)
            {
                ultimo = reloj.ElapsedMilliseconds;
                try { File.WriteAllText(progreso, e.Archivos + "|" + e.Total + "|" + d.FullName, Encoding.UTF8); } catch { }
            }
        }
        e.Grandes = top.OrderByDescending(x => x.Bytes).Take(maxGrandes).ToList();
        return e;
    }
}
'@
}
