@echo off
setlocal
cd /d "%~dp0"
set "VM_DIR=%~dp0"
set "VM_SELF=%~f0"

if not exist "Cargo.toml" (
    echo ERROR: Cargo.toml not found in "%~dp0".
    echo Put this file in the Hyphen source folder, next to Cargo.toml.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -STA -Command "try { $t=[IO.File]::ReadAllText($env:VM_SELF); $i=$t.IndexOf('#=='+'PS=='); Invoke-Expression $t.Substring($i) } catch { $_ | Out-String | Write-Host; exit 1 }"
if errorlevel 1 (
    echo.
    echo The window closed with an error - see the message above.
    pause
)
exit /b 0

#==PS==
$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath $env:VM_DIR
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try {
    Add-Type -Namespace VmWin -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][VmWin.Dpi]::SetProcessDPIAware()
} catch {}
try { Add-Type -AssemblyName PresentationCore } catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class Native
{
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}

public class ProcRunner
{
    public ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    public volatile string Transient = "";
    public volatile bool Exited = false;
    public int ExitCode = -1;
    public int Pid = 0;
    private Process proc;
    private int openStreams = 2;
    private object gate = new object();

    public string Start(string file, string args, string workDir)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(file, args);
            psi.WorkingDirectory = workDir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;
            proc = Process.Start(psi);
            Pid = proc.Id;
            StartReader(proc.StandardOutput);
            StartReader(proc.StandardError);
            Thread w = new Thread(new ThreadStart(Wait));
            w.IsBackground = true;
            w.Start();
            return null;
        }
        catch (Exception ex)
        {
            Exited = true;
            return ex.Message;
        }
    }

    private void StartReader(StreamReader r)
    {
        Thread t = new Thread(new ParameterizedThreadStart(ReadLoop));
        t.IsBackground = true;
        t.Start(r);
    }

    private void ReadLoop(object o)
    {
        StreamReader r = (StreamReader)o;
        StringBuilder sb = new StringBuilder();
        char[] buf = new char[4096];
        bool cr = false;
        int n;
        try
        {
            while ((n = r.Read(buf, 0, buf.Length)) > 0)
            {
                for (int i = 0; i < n; i++)
                {
                    char c = buf[i];
                    if (c == '\r') { cr = true; continue; }
                    if (c == '\n')
                    {
                        if (sb.Length > 0) { Lines.Enqueue(sb.ToString()); Transient = ""; sb.Length = 0; }
                        cr = false;
                        continue;
                    }
                    if (cr)
                    {
                        if (sb.Length > 0) { Transient = sb.ToString(); sb.Length = 0; }
                        cr = false;
                    }
                    sb.Append(c);
                }
            }
        }
        catch (Exception) { }
        if (sb.Length > 0) { Lines.Enqueue(sb.ToString()); }
        lock (gate) { openStreams--; }
    }

    private void Wait()
    {
        try { proc.WaitForExit(); ExitCode = proc.ExitCode; }
        catch (Exception) { ExitCode = -1; }
        for (int i = 0; i < 100; i++)
        {
            bool done;
            lock (gate) { done = (openStreams <= 0); }
            if (done) break;
            Thread.Sleep(20);
        }
        Exited = true;
    }

    public void Kill()
    {
        try
        {
            if (Pid > 0 && !Exited)
            {
                ProcessStartInfo k = new ProcessStartInfo("taskkill", "/PID " + Pid + " /T /F");
                k.CreateNoWindow = true;
                k.UseShellExecute = false;
                Process.Start(k);
            }
        }
        catch (Exception) { }
    }
}

public static class Synth
{
    const int SR = 44100;
    public static volatile bool Done = false;
    public static volatile int Ready = 0;

    static double Hz(int midi) { return 440.0 * Math.Pow(2.0, (midi - 69) / 12.0); }

    static double Saw(double f, double t)
    {
        double s = 0.0;
        for (int k = 1; k <= 6; k++) { s += Math.Sin(2.0 * Math.PI * f * k * t) / k; }
        return s * 0.55;
    }

    static void Add(double[] a, long pos, double v) { a[(int)(pos % a.Length)] += v; }

    public static void RenderAsync(string[] paths)
    {
        Thread th = new Thread(delegate()
        {
            for (int i = 0; i < paths.Length; i++)
            {
                try
                {
                    bool have = File.Exists(paths[i]) && new FileInfo(paths[i]).Length > 100000;
                    if (!have) { Render(paths[i], i); }
                }
                catch (Exception) { }
                if (File.Exists(paths[i])) { Ready = i + 1; Done = true; }
                else { break; }
            }
        });
        th.IsBackground = true;
        th.Start();
    }

    static double TrackBeat(int track)
    {
        if (track == 1) return 0.5;
        if (track == 2) return 0.75;
        if (track == 3) return 0.8;
        if (track == 4) return 0.45;
        return 0.6;
    }

    static void Render(string path, int track)
    {
        Random rnd = new Random(7);
        double beat = TrackBeat(track);
        int slots = 8;
        double slotLen = 8 * beat;
        int n = (int)(slots * slotLen * SR);
        double[] pad = new double[n];
        double[] bass = new double[n];
        double[] arp = new double[n];
        double[] drums = new double[n];
        int[][] chords = new int[][] { new int[] { 57, 60, 64 }, new int[] { 53, 57, 60 }, new int[] { 55, 60, 64 }, new int[] { 55, 59, 62 } };
        int[] roots = new int[] { 45, 41, 48, 43 };
        double[] vel = new double[] { 1.0, 0.55, 0.85, 0.55, 1.0, 0.55, 0.85, 0.55 };
        int[] pat = new int[] { 0, 1, 2, 1, 2, 1, 0, 1 };
        int drumMode = 0;
        int bassStyle = 0;
        double arpAmpMul = 1.0;
        if (track == 1)
        {
            chords = new int[][] { new int[] { 62, 65, 69 }, new int[] { 58, 62, 65 }, new int[] { 57, 60, 65 }, new int[] { 55, 60, 64 } };
            roots = new int[] { 38, 34, 41, 36 };
            pat = new int[] { 0, 2, 1, 2, 0, 2, 1, 2 };
            drumMode = 1; bassStyle = 1;
        }
        else if (track == 2)
        {
            chords = new int[][] { new int[] { 53, 57, 60, 64 }, new int[] { 50, 53, 57, 60 }, new int[] { 58, 62, 65, 69 }, new int[] { 55, 58, 62, 65 } };
            roots = new int[] { 41, 38, 34, 43 };
            pat = new int[] { 0, 1, 2, 3, 2, 1, 0, 1 };
            drumMode = 2; bassStyle = 0; arpAmpMul = 0.8;
        }
        else if (track == 3)
        {
            chords = new int[][] { new int[] { 52, 55, 59 }, new int[] { 48, 52, 55 }, new int[] { 55, 59, 62 }, new int[] { 50, 54, 57 } };
            roots = new int[] { 40, 36, 43, 38 };
            pat = new int[] { 0, 1, 2, 1, 0, 1, 2, 1 };
            drumMode = 3; bassStyle = 2; arpAmpMul = 0.55;
        }
        else if (track == 4)
        {
            chords = new int[][] { new int[] { 60, 63, 67 }, new int[] { 56, 60, 63 }, new int[] { 55, 58, 63 }, new int[] { 58, 62, 65 } };
            roots = new int[] { 36, 32, 39, 34 };
            pat = new int[] { 0, 1, 2, 1, 2, 1, 2, 1 };
            drumMode = 1; bassStyle = 1; arpAmpMul = 1.1;
        }

        for (int s = 0; s < slots; s++)
        {
            int[] ch = chords[s % 4];
            int start = (int)(s * slotLen * SR);
            int len = (int)(slotLen * SR);
            for (int i = 0; i < len; i++)
            {
                double t = (double)i / SR;
                double env = Math.Min(1.0, t / 0.9) * Math.Min(1.0, (slotLen - t) / 0.9);
                if (env <= 0.0) continue;
                double v = 0.0;
                for (int c = 0; c < ch.Length; c++)
                {
                    double f = Hz(ch[c]);
                    v += Saw(f * 0.997, t) + Saw(f * 1.003, t);
                }
                Add(pad, start + i, v * env * 0.026);
            }
        }

        for (int s = 0; s < slots; s++)
        {
            int root = roots[s % 4];
            for (int e = 0; e < 16; e++)
            {
                if (bassStyle == 2 && (e % 8) != 0) continue;
                double startT = s * slotLen + e * beat * 0.5;
                long idx = (long)(startT * SR);
                int len = (int)(beat * 0.5 * SR * 0.95);
                if (bassStyle == 2) len = (int)(beat * 4.0 * SR * 0.95);
                int note = root + ((e % 4 == 2 && bassStyle != 1) ? 12 : 0);
                double f = Hz(note);
                for (int i = 0; i < len; i++)
                {
                    double t = (double)i / SR;
                    double env = Math.Exp(-t * ((bassStyle == 2) ? 0.9 : 5.0)) * Math.Min(1.0, t / 0.004);
                    double wv = Math.Sin(2.0 * Math.PI * f * t) + 0.45 * Math.Sin(4.0 * Math.PI * f * t) + 0.2 * Math.Sin(6.0 * Math.PI * f * t);
                    Add(bass, idx + i, wv * env * vel[e % 8] * 0.2);
                }
            }
        }

        double sixteenth = beat / 4.0;
        for (int s = 0; s < slots; s++)
        {
            int[] ch = chords[s % 4];
            for (int k = 0; k < 32; k++)
            {
                double startT = s * slotLen + k * sixteenth;
                long idx = (long)(startT * SR);
                double f = Hz(ch[pat[k % 8]] + 12);
                double amp = (k % 4 == 0) ? 1.0 : 0.7;
                int len = (int)(0.3 * SR);
                for (int i = 0; i < len; i++)
                {
                    double t = (double)i / SR;
                    double env = Math.Exp(-t * 9.0) * Math.Min(1.0, t / 0.003);
                    double wv = Math.Sin(2.0 * Math.PI * f * t) + 0.3 * Math.Sin(4.0 * Math.PI * f * t);
                    Add(arp, idx + i, wv * env * amp * 0.085 * arpAmpMul);
                }
            }
        }
        double[] arpOut = new double[n];
        int dly = (int)(beat * 0.75 * SR);
        for (int pass = 0; pass < 3; pass++)
        {
            for (int i = 0; i < n; i++)
            {
                int j = i - dly;
                if (j < 0) j += n;
                arpOut[i] = arp[i] + 0.42 * arpOut[j];
            }
        }

        int beats = slots * 8;
        double hpPrev = 0.0;
        for (int b = 0; b < beats; b++)
        {
            double t0 = b * beat;
            long idx = (long)(t0 * SR);
            bool kick = (drumMode == 2 || drumMode == 3) ? (b % 4 == 0) : true;
            double kAmp = (drumMode == 3) ? 0.3 : 0.55;
            int klen = kick ? (int)(0.25 * SR) : 0;
            double ph = 0.0;
            for (int i = 0; i < klen; i++)
            {
                double t = (double)i / SR;
                double f = 45.0 + 85.0 * Math.Exp(-t * 30.0);
                ph += 2.0 * Math.PI * f / SR;
                Add(drums, idx + i, Math.Sin(ph) * Math.Exp(-t * 14.0) * kAmp);
            }
            bool snare = (drumMode == 2) ? (b % 4 == 2) : ((drumMode == 3) ? false : (b % 2 == 1));
            if (snare)
            {
                int slen = (int)(0.2 * SR);
                for (int i = 0; i < slen; i++)
                {
                    double t = (double)i / SR;
                    double noise = rnd.NextDouble() * 2.0 - 1.0;
                    double tone = Math.Sin(2.0 * Math.PI * 190.0 * t);
                    Add(drums, idx + i, (noise * 0.6 + tone * 0.4) * Math.Exp(-t * 18.0) * 0.28);
                }
            }
            int hats = (drumMode == 1) ? 3 : 1;
            for (int hh = 0; hh < hats; hh++)
            {
                double hoff = (hh == 0) ? 0.5 : ((hh == 1) ? 0.25 : 0.75);
                double hv = (hh == 0) ? 1.0 : 0.55;
                if (drumMode == 3) hv = 0.5;
                long hidx = (long)((t0 + beat * hoff) * SR);
                int hlen = (int)(0.06 * SR);
                for (int i = 0; i < hlen; i++)
                {
                    double t = (double)i / SR;
                    double x = rnd.NextDouble() * 2.0 - 1.0;
                    double hp = x - hpPrev;
                    hpPrev = x;
                    Add(drums, hidx + i, hp * Math.Exp(-t * 70.0) * 0.06 * hv);
                }
            }
        }

        double peak = 0.0;
        double[] mix = new double[n];
        for (int i = 0; i < n; i++)
        {
            mix[i] = pad[i] + bass[i] + arpOut[i] + drums[i];
            double a = Math.Abs(mix[i]);
            if (a > peak) peak = a;
        }
        double g = (peak > 0.0) ? 0.85 / peak : 1.0;
        int repeats = 3;
        int dataLen = n * repeats * 2;
        string tmp = path + ".tmp";
        using (FileStream fs = new FileStream(tmp, FileMode.Create))
        using (BinaryWriter bw = new BinaryWriter(fs))
        {
            bw.Write(new char[] { 'R', 'I', 'F', 'F' });
            bw.Write(36 + dataLen);
            bw.Write(new char[] { 'W', 'A', 'V', 'E' });
            bw.Write(new char[] { 'f', 'm', 't', ' ' });
            bw.Write(16);
            bw.Write((short)1);
            bw.Write((short)1);
            bw.Write(SR);
            bw.Write(SR * 2);
            bw.Write((short)2);
            bw.Write((short)16);
            bw.Write(new char[] { 'd', 'a', 't', 'a' });
            bw.Write(dataLen);
            for (int rep = 0; rep < repeats; rep++)
            {
                for (int i = 0; i < n; i++)
                {
                    double v = mix[i] * g * 32767.0;
                    if (v > 32767.0) v = 32767.0;
                    if (v < -32767.0) v = -32767.0;
                    bw.Write((short)v);
                }
            }
        }
        if (File.Exists(path)) File.Delete(path);
        File.Move(tmp, path);
    }
}
'@

# ------------------------------------------------------------------
# Settings
# ------------------------------------------------------------------
$ScriptDir    = $env:VM_DIR.TrimEnd('\')
$SettingsFile = Join-Path $ScriptDir 'hyphen_gui.json'
$Bin          = Join-Path $ScriptDir 'target\release\victory.exe'
$Stamp        = Join-Path $ScriptDir 'target\.victory_built'
$MusicWav     = Join-Path $env:TEMP 'victory_neon_sunset_v1.wav'
$HaveGit      = [bool](Get-Command git -ErrorAction SilentlyContinue)
[string[]]$MusicTracks = @(0..4 | ForEach-Object { Join-Path $env:TEMP ('victory_neon_t' + $_ + '_v2.wav') })
$MusicNames   = @('1  Neon Sunset', '2  Night Drive', '3  Palm Haze', '4  Midnight Boulevard', '5  Chrome Skyline')

$Defaults = @{
    RepoUrl    = 'https://github.com/fxceless/victory-fork.git'
    GameDir    = 'D:\New folder\GTA6'
    GameExe    = 'game.exe'
    CacheDir   = 'D:\Hyphen-data\cache'
    DataDir    = 'D:\Hyphen-data\data'
    OldDir     = (Join-Path $env:LOCALAPPDATA 'victory')
    Jobs       = 6
    AutoJobs   = $false
    ExpectedFiles = 0
    LastBuildSec  = 0
    LastShaderWork = 11600
    ShaderStamp = ''
    OptBuild   = $false
    MusicOn    = $false
    MusicFile  = ''
    MusicTrack = 0
    Layout = 'Detailed'
    Resize = 'Drag'
    SecH = ''
    ColW = 0
    TileH = 0
    CacheH = 0
    MusicVol   = 40
    LaunchProg = '{BIN}'
    LaunchArgs = 'run "{EXE}" --execute'
    ZipFile    = ''
}

function Load-Settings {
    $h = @{}
    foreach ($k in $Defaults.Keys) { $h[$k] = $Defaults[$k] }
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
            foreach ($k in @($h.Keys)) {
                if ($null -ne $j.$k) { $h[$k] = $j.$k }
            }
        } catch {}
    }
    return $h
}

$Cfg = Load-Settings
$Cfg.Layout = 'Detailed'
$FirstRun = -not (Test-Path -LiteralPath $SettingsFile)

$S = @{
    Queue = (New-Object System.Collections.ArrayList)
    Runner = $null; Bg = $null; BgReport = $false; RepoFail = $false
    Cur = $null; Running = $false; Stopping = $false; FuncFail = $false
    Done = 0; Total = 0; StepName = ''; Start = $null; Title = ''
    Ticks = 0; EnvSet = (New-Object System.Collections.ArrayList)
    ScanPS = $null; ScanAsync = $null; Prev = @{}; PrevCpu = @{}; ProcT = (Get-Date)
    Age = $null; VicRun = $false; CargoRun = $false; GitRun = $false
    LastErr = ''; TomlBak = $null; Behind = 0
    HwPS = $null; HwAsync = $null; SpeedBase = $null; SpeedT = $null; SpeedTxt = ''
    StepFrac = $null; FracFiles = $null; StepStart = $null; WeightTotal = 0.0; WeightDone = 0.0; LastDx = 0
    OverallPct = 0.0; OverallText = 'Overall'; StepPct = 0.0; StepText = 'Step'; StepIndet = $false
    Player = $null; MusicOn = $false; MusicWait = $false
    AnsiPat = '\x1b\[[0-9;?]*[A-Za-z]'
}

$colBlue  = [System.Drawing.Color]::FromArgb(0, 220, 235)
$colRed   = [System.Drawing.Color]::FromArgb(255, 85, 115)
$colGreen = [System.Drawing.Color]::FromArgb(70, 230, 150)
$colAmber = [System.Drawing.Color]::FromArgb(255, 175, 70)
$colGray  = [System.Drawing.Color]::FromArgb(165, 155, 195)

$ScanScript = @'
param($paths)
$out = @()
foreach ($p in $paths) {
    $n = 0; $bytes = [long]0
    $rec = New-Object System.Collections.ArrayList
    $cut = (Get-Date).AddMinutes(-15)
    try {
        if (Test-Path -LiteralPath $p.Path) {
            foreach ($f in ([IO.DirectoryInfo]$p.Path).EnumerateFiles('*', 'AllDirectories')) {
                $n++; $bytes += $f.Length
                if ($f.LastWriteTime -gt $cut) { [void]$rec.Add(@($f.LastWriteTime, $f.Length, $f.FullName)) }
            }
        }
    } catch {}
    $recent = @($rec | Sort-Object { $_[0] } -Descending | Select-Object -First 6)
    $out += [pscustomobject]@{ Tag = $p.Tag; Root = $p.Path; Files = $n; Bytes = $bytes; Recent = $recent; At = (Get-Date) }
}
return $out
'@

# ------------------------------------------------------------------
# Small helpers
# ------------------------------------------------------------------
function Fmt-Time($ts) {
    if ($ts -lt [TimeSpan]::Zero) { $ts = [TimeSpan]::Zero }
    return ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

function Guard([scriptblock]$sb) {
    try { & $sb }
    catch {
        [System.Windows.Forms.MessageBox]::Show(($_ | Out-String), 'Hyphen Manager - error') | Out-Null
    }
}

function Write-Log([string]$text, $color) {
    $rtb.SelectionStart = $rtb.TextLength
    $rtb.SelectionLength = 0
    if ($color) { $rtb.SelectionColor = $color } else { $rtb.SelectionColor = $rtb.ForeColor }
    $rtb.AppendText($text + "`r`n")
    $rtb.SelectionColor = $rtb.ForeColor
    if ($rtb.TextLength -gt 400000) { $rtb.Select(0, 150000); $rtb.SelectedText = '' }
    $rtb.SelectionStart = $rtb.TextLength
    $rtb.ScrollToCaret()
}

function Fix-Dir([string]$p) {
    $p = $p.Trim().Trim('"')
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }
    return $p
}

function Get-Jobs {
    if ($Cfg.AutoJobs) { return [int][math]::Max(1, [Environment]::ProcessorCount - 1) }
    return [int]$Cfg.Jobs
}

function Read-UI {
    $Cfg.GameDir    = Fix-Dir $txtGame.Text
    $Cfg.CacheDir   = Fix-Dir $txtCache.Text
    $Cfg.DataDir    = Fix-Dir $txtData.Text
    $Cfg.OldDir     = Fix-Dir $txtOld.Text
    $Cfg.RepoUrl    = $txtRepo.Text.Trim()
    $Cfg.GameExe    = $txtExe.Text.Trim()
    $Cfg.Jobs       = [int]$numJobs.Value
    $Cfg.AutoJobs   = [bool]$chkAuto.Checked
    $Cfg.OptBuild   = [bool]$chkOpt.Checked
    $Cfg.LaunchProg = $txtProg.Text.Trim()
    $Cfg.LaunchArgs = $txtArgs.Text.Trim()
    $Cfg.ExpectedFiles = [int]$numExp.Value
}

function Save-Settings {
    try {
        $o = New-Object PSObject
        foreach ($k in $Defaults.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $Cfg[$k] }
        $o | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    } catch {
        Write-Log ('Could not save settings: ' + $_.Exception.Message) $colAmber
    }
}

function Apply-Env {
    $env:VICTORY_GAME_DIR  = $Cfg.GameDir
    $env:VICTORY_CACHE_DIR = $Cfg.CacheDir
    $env:VICTORY_DATA_DIR  = $Cfg.DataDir
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:CARGO_NET_GIT_FETCH_WITH_CLI = 'true'
    $env:CARGO_INCREMENTAL = '0'
    if (Get-Command sccache -ErrorAction SilentlyContinue) { $env:RUSTC_WRAPPER = 'sccache' }
    if ($Cfg.OptBuild) {
        $env:CARGO_PROFILE_RELEASE_LTO = 'thin'
        $env:CARGO_PROFILE_RELEASE_CODEGEN_UNITS = '1'
        $env:RUSTFLAGS = '-C target-cpu=native'
        $script:OptEnvSet = $true
    } elseif ($script:OptEnvSet) {
        Remove-Item Env:CARGO_PROFILE_RELEASE_LTO -ErrorAction SilentlyContinue
        Remove-Item Env:CARGO_PROFILE_RELEASE_CODEGEN_UNITS -ErrorAction SilentlyContinue
        Remove-Item Env:RUSTFLAGS -ErrorAction SilentlyContinue
        $script:OptEnvSet = $false
    }
}

function Set-Busy([bool]$busy) {
    foreach ($b in @($btnFull, $btnShaders, $btnSync, $btnLaunch, $btnCheck, $btnMigrate, $btnZip)) { $b.Enabled = (-not $busy) }
    $btnStop.Enabled = $busy
}

# ------------------------------------------------------------------
# Git helpers (quick local commands only)
# ------------------------------------------------------------------
function Get-GitOut([string[]]$a) {
    if (-not $HaveGit) { return $null }
    try {
        $o = & git @a 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (($o | Out-String).Trim())
    } catch { return $null }
}

function Get-Branch {
    if ($null -ne (Get-GitOut @('show-ref', '--verify', '--quiet', 'refs/remotes/origin/main'))) { return 'main' }
    if ($null -ne (Get-GitOut @('show-ref', '--verify', '--quiet', 'refs/remotes/origin/master'))) { return 'master' }
    return $null
}

function Ensure-Remote {
    if (-not $HaveGit) { return }
    try {
        & git remote set-url origin $Cfg.RepoUrl 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { & git remote add origin $Cfg.RepoUrl 2>$null | Out-Null }
    } catch {}
}

function Update-RepoStatus {
    $S.Behind = 0
    if (-not $HaveGit) { $lblRepo.Text = 'Repo: git is not installed'; $lblRepo.ForeColor = $colAmber; return }
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptDir '.git'))) {
        $lblRepo.Text = 'Repo: not linked to GitHub yet - "Sync + Build" will link it'
        $lblRepo.ForeColor = $colAmber
        return
    }
    $br = Get-Branch
    if (-not $br) { $lblRepo.Text = 'Repo: no GitHub data yet - press Check Updates'; $lblRepo.ForeColor = $colGray; return }
    $local = Get-GitOut @('rev-parse', '--short', 'HEAD')
    $msg   = Get-GitOut @('log', '-1', '--pretty=format:%h (%cr) - %s', ('origin/' + $br))
    if ($msg -and $msg.Length -gt 80) { $msg = $msg.Substring(0, 77) + '...' }
    if (-not $local) {
        $S.Behind = 1
        $lblRepo.Text = 'Repo: folder not linked yet - latest on GitHub: ' + $msg
        $lblRepo.ForeColor = $colAmber
        return
    }
    $b = Get-GitOut @('rev-list', '--count', ('HEAD..origin/' + $br))
    $n = 0
    if ($b) { [void][int]::TryParse($b, [ref]$n) }
    $S.Behind = $n
    if ($n -gt 0) {
        $lblRepo.Text = 'Repo: UPDATE AVAILABLE (' + $n + ' new commit(s)) - latest: ' + $msg
        $lblRepo.ForeColor = $colAmber
    } else {
        $lblRepo.Text = 'Repo: up to date (' + $local + ' on ' + $br + ') - latest: ' + $msg
        $lblRepo.ForeColor = $colGreen
    }
}

function Start-BgFetch([bool]$report) {
    if ($S.Bg -or $S.Running) { return }
    if (-not $HaveGit -or -not (Test-Path -LiteralPath (Join-Path $ScriptDir '.git'))) { Update-RepoStatus; return }
    Ensure-Remote
    $S.BgReport = $report
    $S.Bg = New-Object ProcRunner
    $err = $S.Bg.Start('git', 'fetch origin --quiet --no-tags', $ScriptDir)
    if ($err) { $S.Bg = $null; $lblRepo.Text = 'Repo: could not run git'; return }
    $lblRepo.Text = 'Repo: checking GitHub...'
    $lblRepo.ForeColor = $colGray
}

function Bg-Done {
    $code = $S.Bg.ExitCode
    $S.Bg = $null
    $S.RepoFail = ($code -ne 0)
    Update-RepoStatus
    if ($S.RepoFail) { $lblRepo.Text = 'Repo: could not reach GitHub (offline?)'; $lblRepo.ForeColor = $colAmber }
    if ($S.BgReport) {
        if ($S.RepoFail) { Write-Log 'Could not reach GitHub. Check your internet connection.' $colAmber; return }
        $br = Get-Branch
        if ($S.Behind -gt 0 -and $br) {
            Write-Log ('New commits on GitHub (' + $S.Behind + '):') $colBlue
            $o = Get-GitOut @('log', ('HEAD..origin/' + $br), '--oneline', '-n', '10')
            if ($o) { foreach ($ln in ($o -split "`n")) { Write-Log ('  ' + $ln.Trim()) } }
            $timer.Stop()
            $ans = [System.Windows.Forms.MessageBox]::Show(('There are ' + $S.Behind + ' new commit(s) on GitHub.' + "`r`n`r`n" + 'Update and build now?'), 'Update available', 'YesNo', 'Question')
            $timer.Start()
            if ($ans -eq 'Yes') { Run-Sync }
            else { Write-Log 'Press "UPDATE + Build" whenever you want to update.' $colBlue }
        } else {
            Write-Log 'You are up to date. Recent commits:' $colGreen
            $o = Get-GitOut @('log', '-n', '5', '--oneline')
            if ($o) { foreach ($ln in ($o -split "`n")) { Write-Log ('  ' + $ln.Trim()) } }
        }
    }
}

# ------------------------------------------------------------------
# Steps
# ------------------------------------------------------------------
function Step-Func($name, [scriptblock]$run, $fatal = $true) {
    return @{ Name = $name; Kind = 'func'; Run = $run; Fatal = $fatal; Skip = $null; Weight = 0.1; Learn = $null; LearnFiles = $false }
}

function Step-Proc($name, $file, $argStr, $fatal = $true) {
    return @{ Name = $name; Kind = 'proc'; File = $file; Args = $argStr; Fatal = $fatal; OkMax = 0; Retries = 0; Tried = 0; Skip = $null; After = $null; Env = $null; Weight = 1.0; Learn = $null; LearnFiles = $false }
}

function Insert-Steps($list) {
    $S.Queue.InsertRange(0, $list)
    $S.Total = $S.Total + $list.Count
    foreach ($x in $list) { $S.WeightTotal = $S.WeightTotal + [double]$x.Weight }
}

function Add-Done($st) { $S.WeightDone = $S.WeightDone + [double]$st.Weight }

function Parse-Progress([string]$t) {
    if ($t -match '(\d{1,3}(?:\.\d+)?)\s*%') {
        $v = [double]$Matches[1]
        if ($v -ge 0 -and $v -le 100) { $S.StepFrac = $v / 100.0; return }
    }
    if ($t -match '(?<![\d/])(\d[\d,]*)\s*/\s*(\d[\d,]*)(?![\d/])') {
        $a = [double]($Matches[1] -replace ',', '')
        $b = [double]($Matches[2] -replace ',', '')
        if ($b -ge 5 -and $a -le $b) { $S.StepFrac = $a / $b }
    }
}

function Learn-FromStep($st) {
    if ($st.Learn -and $S.StepStart) {
        $sec = [int](((Get-Date) - $S.StepStart).TotalSeconds)
        if ($sec -ge 20) {
            $jb = Get-Jobs
            if ($st.JobsUsed) { $jb = [int]$st.JobsUsed }
            if ($st.Learn -eq 'LastShaderWork') { $Cfg[$st.Learn] = [int]($sec * [math]::Max(1, $jb)) }
            else { $Cfg[$st.Learn] = $sec }
            Save-Settings
        }
    }
    if ($st.LearnFiles -and $S.LastDx -gt 0) {
        $Cfg.ExpectedFiles = [int][math]::Min(5000000, $S.LastDx)
        $numExp.Value = [decimal]$Cfg.ExpectedFiles
        Save-Settings
    }
}

function Do-Toml {
    $toml = Join-Path $ScriptDir 'victory.toml'
    $ex   = Join-Path $ScriptDir 'victory.example.toml'
    if (-not (Test-Path -LiteralPath $toml)) {
        if (Test-Path -LiteralPath $ex) {
            Copy-Item -LiteralPath $ex -Destination $toml
            Write-Log '  created victory.toml from victory.example.toml'
        } else {
            Write-Log 'ERROR: neither victory.toml nor victory.example.toml was found.' $colRed
            $S.FuncFail = $true
            return
        }
    }
    foreach ($d in @($Cfg.CacheDir, $Cfg.DataDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    if (-not (Test-Path -LiteralPath $Cfg.GameDir)) {
        Write-Log ('  WARNING: game folder not found: ' + $Cfg.GameDir) $colAmber
    }
    $txt = [IO.File]::ReadAllText($toml)
    $new = $txt
    $new = [regex]::Replace($new, '(?m)^#?[ \t]*game_dir[ \t]*=[^\r\n]*',  [System.Text.RegularExpressions.MatchEvaluator]{ param($m) "game_dir = '" + $Cfg.GameDir + "'" })
    $new = [regex]::Replace($new, '(?m)^#?[ \t]*cache_dir[ \t]*=[^\r\n]*', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) "cache_dir = '" + $Cfg.CacheDir + "'" })
    $new = [regex]::Replace($new, '(?m)^#?[ \t]*data_dir[ \t]*=[^\r\n]*',  [System.Text.RegularExpressions.MatchEvaluator]{ param($m) "data_dir = '" + $Cfg.DataDir + "'" })
    if ($new -ne $txt) {
        [IO.File]::WriteAllText($toml, $new, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log '  updated victory.toml with your folders'
    } else {
        Write-Log '  victory.toml already matches your folders'
    }
}

function Do-GitPrepare {
    if (-not $HaveGit) { Write-Log '  git is not installed - skipping repo sync' $colAmber; return }
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptDir '.git'))) { & git init -q 2>$null | Out-Null }
    $lock = Join-Path $ScriptDir '.git\index.lock'
    if ((Test-Path -LiteralPath $lock) -and -not (Get-Process -Name git -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        Write-Log '  removed a stale git lock file left by an interrupted git command' $colAmber
    }
    Ensure-Remote
}

function Do-GitUpdate {
    if (-not $HaveGit) { return }
    $branch = Get-Branch
    if (-not $branch) { Write-Log '  no GitHub branch found - keeping your local files' $colAmber; return }
    $remote = Get-GitOut @('rev-parse', ('origin/' + $branch))
    $head   = Get-GitOut @('rev-parse', 'HEAD')
    if ($head -and $remote -and ($head -eq $remote)) {
        Write-Log '  already at the latest commit' $colGreen
        Update-RepoStatus
        return
    }
    $toml = Join-Path $ScriptDir 'victory.toml'
    $S.TomlBak = $null
    if (Test-Path -LiteralPath $toml) { $S.TomlBak = [IO.File]::ReadAllText($toml) }
    $ins = New-Object System.Collections.ArrayList
    [void]$ins.Add((Step-Proc 'Checkout latest files' 'git' ('checkout -q -f -B ' + $branch + ' origin/' + $branch) $true))
    [void]$ins.Add((Step-Func 'Check the update applied' { Do-VerifyUpdate } $false))
    [void]$ins.Add((Step-Func 'Restore victory.toml' { Do-RestoreToml } $false))
    $sm = Step-Proc 'Update submodules' 'git' 'submodule update --init --recursive --jobs 8' $false
    $sm.Skip = { -not (Test-Path -LiteralPath (Join-Path $ScriptDir '.gitmodules')) }
    [void]$ins.Add($sm)
    Insert-Steps $ins
}

function Do-VerifyUpdate {
    $branch = Get-Branch
    $remote = Get-GitOut @('rev-parse', ('origin/' + $branch))
    $head   = Get-GitOut @('rev-parse', 'HEAD')
    if ($head -and $remote -and ($head -eq $remote)) { Write-Log '  update applied' $colGreen; return }
    Write-Log '  the checkout did not reach the latest commit - forcing it with reset --hard' $colAmber
    $ins = New-Object System.Collections.ArrayList
    [void]$ins.Add((Step-Proc 'Force update (git reset --hard)' 'git' ('reset --hard origin/' + $branch) $true))
    Insert-Steps $ins
}

function Do-RestoreToml {
    if ($null -ne $S.TomlBak) {
        [IO.File]::WriteAllText((Join-Path $ScriptDir 'victory.toml'), $S.TomlBak, (New-Object System.Text.UTF8Encoding($false)))
    }
    Update-RepoStatus
}

function Get-BuildTag {
    $h = Get-GitOut @('rev-parse', 'HEAD')
    if (-not $h) { return $null }
    if ($Cfg.OptBuild) { $h = $h + '|opt' }
    return $h
}

function Test-BuildCurrent([bool]$useStamp) {
    if (-not (Test-Path -LiteralPath $Bin)) { return $false }
    if (-not $useStamp) { return $true }
    if (-not (Test-Path -LiteralPath $Stamp)) { return $false }
    $h = Get-BuildTag
    if (-not $h) { return $false }
    $b = [string](Get-Content -LiteralPath $Stamp -TotalCount 1)
    return ($b.Trim() -eq $h)
}

function Do-CheckCargo {
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        Write-Log 'ERROR: cargo (Rust) was not found. Install it from https://rustup.rs and try again.' $colRed
        $S.FuncFail = $true
    }
}

function Do-WriteStamp {
    $h = Get-BuildTag
    if ($h) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Stamp) | Out-Null
        [IO.File]::WriteAllText($Stamp, $h)
    }
}

function Do-Launch {
    $exe = Join-Path $Cfg.GameDir $Cfg.GameExe
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Log ('ERROR: game file not found: ' + $exe) $colRed
        $S.FuncFail = $true
        return
    }
    $prog = $Cfg.LaunchProg.Replace('{BIN}', $Bin).Replace('{EXE}', $exe).Replace('{GAMEDIR}', $Cfg.GameDir).Replace('{ROOT}', $ScriptDir).Replace('{CACHE}', $Cfg.CacheDir).Replace('{DATA}', $Cfg.DataDir)
    $argText = $Cfg.LaunchArgs.Replace('{BIN}', $Bin).Replace('{EXE}', $exe).Replace('{GAMEDIR}', $Cfg.GameDir).Replace('{ROOT}', $ScriptDir).Replace('{CACHE}', $Cfg.CacheDir).Replace('{DATA}', $Cfg.DataDir)
    Write-Log ('  > ' + $prog + ' ' + $argText) $colGray
    $sp = @{ FilePath = $prog; WorkingDirectory = $Cfg.GameDir }
    if ($argText.Trim()) { $sp.ArgumentList = $argText }
    try { Start-Process @sp }
    catch {
        Write-Log ('ERROR: could not start it: ' + $_.Exception.Message) $colRed
        $S.FuncFail = $true
        return
    }
    Write-Log '  started in its own window - close that window to stop it' $colGreen
}

function Do-ZipGet {
    $zip = [string]$S.ZipPath
    if (-not $zip) {
        $base = $Cfg.RepoUrl.Trim()
        if ($base.EndsWith('.git')) { $base = $base.Substring(0, $base.Length - 4) }
        $br = 'main'
        try { $b0 = Get-Branch; if ($b0) { $br = $b0 } } catch {}
        $url = $base.TrimEnd('/') + '/archive/refs/heads/' + $br + '.zip'
        $zip = Join-Path $env:TEMP 'hyphen_source.zip'
        Write-Log ('  downloading ' + $url) $colGray
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        } catch {
            Write-Log ('ERROR: download failed: ' + $_.Exception.Message) $colRed
            $S.FuncFail = $true
            return
        }
    }
    if (-not (Test-Path -LiteralPath $zip)) { Write-Log ('ERROR: ZIP not found: ' + $zip) $colRed; $S.FuncFail = $true; return }
    Write-Log ('  using ' + $zip + '  (' + [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1) + ' MB)') $colGray
    $tmp = Join-Path $env:TEMP 'hyphen_unzip'
    $src = Join-Path $env:TEMP 'hyphen_src'
    foreach ($d in @($tmp, $src)) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
    } catch {
        Write-Log ('ERROR: could not open the ZIP: ' + $_.Exception.Message) $colRed
        $S.FuncFail = $true
        return
    }
    $root = $null
    if (Test-Path -LiteralPath (Join-Path $tmp 'Cargo.toml')) { $root = $tmp }
    else {
        foreach ($d in (Get-ChildItem -LiteralPath $tmp -Directory)) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'Cargo.toml')) { $root = $d.FullName; break }
        }
    }
    if (-not $root) {
        Write-Log 'ERROR: that ZIP does not contain a Cargo.toml - it is not the Hyphen source.' $colRed
        $S.FuncFail = $true
        return
    }
    Move-Item -LiteralPath $root -Destination $src -Force
    Write-Log '  ZIP unpacked - copying files next' $colGray
}

function Add-ZipSteps($l) {
    [void]$l.Add((Step-Func 'Get the source ZIP' { Do-ZipGet } $true))
    $src = Join-Path $env:TEMP 'hyphen_src'
    $a = '"' + $src + '" "' + $ScriptDir + '" /E /XD target .git /XF victory.toml hyphen_gui.json Hyphen.bat victory_gui.json victory_gui.bat /MT:16 /NP /R:1 /W:1 /NJH'
    $cp = Step-Proc 'Copy new files over this folder' 'robocopy' $a $true
    $cp.OkMax = 7
    $cp.Weight = 1.5
    [void]$l.Add($cp)
}

function Add-TomlStep($l) {
    [void]$l.Add((Step-Func 'Check victory.toml and folders' { Do-Toml } $true))
}

function Add-ValidateStep($l, [bool]$fatal) {
    $v = Step-Proc 'Validate config' $Bin 'config' $fatal
    $v.Weight = 0.3
    $v.Skip = { -not (Test-Path -LiteralPath $Bin) }
    [void]$l.Add($v)
}

function Add-SyncSteps($l) {
    [void]$l.Add((Step-Func 'Prepare git' { Do-GitPrepare } $false))
    $f = Step-Proc 'Fetch from GitHub' 'git' 'fetch origin --prune --no-tags' $false
    $f.Skip = { -not $HaveGit }
    [void]$l.Add($f)
    [void]$l.Add((Step-Func 'Update source files' { Do-GitUpdate } $false))
}

function Add-BuildSteps($l, [bool]$useStamp) {
    $c = Step-Func 'Check Rust (cargo)' { Do-CheckCargo } $true
    $b = Step-Proc 'Build victory (cargo build --release)' 'cargo' 'build --release -p victory' $true
    $b.After = { Do-WriteStamp }
    $b.Weight = 6.0
    $b.Learn = 'LastBuildSec'
    if ($useStamp) {
        $c.Skip = { Test-BuildCurrent $true }
        $b.Skip = { Test-BuildCurrent $true }
    } else {
        $c.Skip = { Test-BuildCurrent $false }
        $b.Skip = { Test-BuildCurrent $false }
    }
    [void]$l.Add($c)
    [void]$l.Add($b)
}

function Get-ShaderKey {
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add([string]$Cfg.GameDir)
    [void]$parts.Add([string]$Cfg.CacheDir)
    foreach ($p in @($Bin, (Join-Path ([string]$Cfg.GameDir) ([string]$Cfg.GameExe)))) {
        try { $fi = Get-Item -LiteralPath $p -ErrorAction Stop; [void]$parts.Add($fi.FullName + '|' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks) }
        catch { [void]$parts.Add('none') }
    }
    return ($parts -join ';')
}

function Test-ShaderStampSkip {
    if ($S.Title -eq 'Pre-compile shaders and pipelines') { return $false }
    if (-not $Cfg.ShaderStamp) { return $false }
    if ([string]$Cfg.ShaderStamp -ne (Get-ShaderKey)) { return $false }
    Write-Log '  already compiled for this exe and game - skipping (use the Compile Shaders button to run it anyway)' $colGreen
    return $true
}

function Write-ShaderStamp {
    $Cfg.ShaderStamp = Get-ShaderKey
    Save-Settings
}

function Add-ShaderSteps($l) {
    $j = Get-Jobs
    $st = Step-Proc 'Pre-compile shaders and pipelines' $Bin ('translate "' + $Cfg.GameDir + '" --pipelines --jobs ' + $j) $true
    $st.Retries = 2
    $st.Weight = 20.0
    $st.LearnFiles = $true
    $st.Learn = 'LastShaderWork'
    $st.JobsUsed = $j
    $st.Skip = { Test-ShaderStampSkip }
    $st.After = { Write-ShaderStamp }
    $st.Env = @{ VICTORY_LOG = 'victory_shader=info,victory_pipeline=info,info' }
    [void]$l.Add($st)
}

function Add-LaunchStep($l) {
    [void]$l.Add((Step-Func 'Launch the game' { Do-Launch } $true))
}

function Add-MigrateSteps($l) {
    [void]$l.Add((Step-Func 'Prepare folders' {
        foreach ($d in @($Cfg.CacheDir, $Cfg.DataDir)) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        }
    } $true))
    $old1 = Join-Path $Cfg.OldDir 'cache'
    $old2 = Join-Path $Cfg.OldDir 'data'
    $any = $false
    if (Test-Path -LiteralPath $old1) {
        $any = $true
        $a = Step-Proc 'Move old cache files' 'robocopy' ('"' + $old1 + '" "' + $Cfg.CacheDir + '" /E /XC /XN /XO /MOVE /MT:16 /NFL /NDL /NJH') $true
        $a.OkMax = 7
        $a.Weight = 3.0
        [void]$l.Add($a)
    }
    if (Test-Path -LiteralPath $old2) {
        $any = $true
        $b = Step-Proc 'Move old data files' 'robocopy' ('"' + $old2 + '" "' + $Cfg.DataDir + '" /E /XC /XN /XO /MOVE /MT:16 /NFL /NDL /NJH') $true
        $b.OkMax = 7
        $b.Weight = 3.0
        [void]$l.Add($b)
    }
    if (-not $any) { [void]$l.Add((Step-Func 'Nothing to move' { Write-Log ('  no cache or data folders found in ' + $Cfg.OldDir) } $false)) }
}

# ------------------------------------------------------------------
# Pipeline engine
# ------------------------------------------------------------------
function Clear-StepEnv {
    foreach ($k in $S.EnvSet) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
    $S.EnvSet.Clear()
}

function Start-Pipeline([string]$title, $steps) {
    if ($S.Running) { return }
    $S.Queue.Clear()
    foreach ($st in $steps) { [void]$S.Queue.Add($st) }
    $S.Total = $S.Queue.Count
    $S.Done = 0
    $S.Running = $true
    $S.Stopping = $false
    $S.Title = $title
    $S.Start = Get-Date
    $S.WeightDone = 0.0
    $S.WeightTotal = 0.0
    foreach ($x in $steps) { $S.WeightTotal = $S.WeightTotal + [double]$x.Weight }
    $S.StepFrac = $null; $S.FracFiles = $null; $S.StepStart = $null; $S.StepIndet = $false
    $S.OverallPct = 0.0; $S.StepPct = 0.0; $S.OverallText = 'Overall 0%'; $S.StepText = 'Step'
    Write-Log ('=== ' + $title + ' ===') $colBlue
    Set-Busy $true
    Next-Step
}

function Next-Step {
    while ($true) {
        if ($S.Queue.Count -eq 0) { Finish-Pipeline $true; return }
        $st = $S.Queue[0]
        $S.Queue.RemoveAt(0)
        $S.Done = $S.Done + 1
        $S.Cur = $st
        $S.StepName = $st.Name
        $tag = ''
        if ($st.Tried -gt 0) { $tag = ' (pass ' + ($st.Tried + 1) + ')' }
        Write-Log ('[' + $S.Done + '/' + $S.Total + '] ' + $st.Name + $tag) $colBlue
        if ($st.Skip -and (& $st.Skip)) { Write-Log '  skipped - not needed' $colGray; Add-Done $st; continue }
        if ($st.Kind -eq 'func') {
            $S.FuncFail = $false
            try { & $st.Run }
            catch { Write-Log ('ERROR: ' + $_.Exception.Message) $colRed; $S.FuncFail = $true }
            if ($S.FuncFail -and $st.Fatal) { Finish-Pipeline $false; return }
            Add-Done $st
            continue
        }
        if ($st.Env) {
            foreach ($k in $st.Env.Keys) {
                [Environment]::SetEnvironmentVariable($k, [string]$st.Env[$k], 'Process')
                [void]$S.EnvSet.Add($k)
            }
        }
        Write-Log ('  > ' + $st.File + ' ' + $st.Args) $colGray
        $S.StepStart = Get-Date
        $S.StepFrac = $null
        $S.FracFiles = $null
        $S.Runner = New-Object ProcRunner
        $err = $S.Runner.Start([string]$st.File, [string]$st.Args, $ScriptDir)
        if ($err) {
            Write-Log ('  could not start ' + $st.File + ': ' + $err) $colRed
            $S.Runner = $null
            Clear-StepEnv
            if ($st.Fatal) { Finish-Pipeline $false; return }
            Add-Done $st
            continue
        }
        return
    }
}

function Handle-Exit {
    $code = $S.Runner.ExitCode
    $S.Runner = $null
    Clear-StepEnv
    $st = $S.Cur
    $okMax = 0
    if ($st.OkMax) { $okMax = [int]$st.OkMax }
    if ($S.Stopping) { Finish-Pipeline $false; return }
    if ($code -ge 0 -and $code -le $okMax) {
        Write-Log '  done' $colGreen
        if ($st.After) {
            try { & $st.After }
            catch { Write-Log ('  (note: ' + $_.Exception.Message + ')') $colAmber }
        }
        Learn-FromStep $st
        Add-Done $st
        Next-Step
        return
    }
    Write-Log ('  exited with code ' + $code) $colRed
    if ($st.Retries -gt 0 -and $st.Tried -lt $st.Retries) {
        $st.Tried = $st.Tried + 1
        Write-Log ('  retrying (pass ' + ($st.Tried + 1) + ' of ' + ($st.Retries + 1) + ') - progress so far is kept in the cache') $colAmber
        $S.Queue.Insert(0, $st)
        $S.Done = $S.Done - 1
        Next-Step
        return
    }
    if ($st.Fatal) { Finish-Pipeline $false; return }
    Write-Log '  (continuing anyway)' $colAmber
    Add-Done $st
    Next-Step
}

function Finish-Pipeline([bool]$ok) {
    $el = (Get-Date) - $S.Start
    $wasStop = $S.Stopping
    $S.Running = $false
    $S.Runner = $null
    $S.Queue.Clear()
    Clear-StepEnv
    Set-Busy $false
    if ($S.Stopping) { Write-Log ('--- Stopped after ' + (Fmt-Time $el)) $colAmber }
    elseif ($ok) { Write-Log ('--- Finished OK in ' + (Fmt-Time $el)) $colGreen }
    else { Write-Log ('--- FAILED at step "' + $S.StepName + '" after ' + (Fmt-Time $el) + ' - see the messages above') $colRed }
    $S.Stopping = $false
    $S.StepIndet = $false
    if ($ok) { $S.OverallPct = 100.0; $S.StepPct = 100.0; $S.OverallText = 'Overall 100%   done'; $S.StepText = 'Step done' }
    elseif ($wasStop) { $S.OverallText = 'Overall stopped at ' + [int]$S.OverallPct + '%'; $S.StepText = 'Stopped' }
    else { $S.OverallText = 'Overall FAILED at ' + [int]$S.OverallPct + '%'; $S.StepText = 'Failed' }
    $barOverall.Invalidate()
    $barStep.Invalidate()
    $lblEtaStep.Text = 'ETA --:--:--'
    $lblEtaStep.ForeColor = $colGray
    if ($ok) { $lblEtaOverall.Text = 'Finished'; $lblEtaOverall.ForeColor = $colGreen }
    else { $lblEtaOverall.Text = 'ETA --:--:--'; $lblEtaOverall.ForeColor = $colGray }
    $lblLive.Text = ''
    Update-RepoStatus
}

function Stop-All {
    $S.Stopping = $true
    $S.Queue.Clear()
    if ($S.Runner) { $S.Runner.Kill() }
    if ($S.Bg) { $S.Bg.Kill() }
}

function Begin-Action {
    if ($S.Bg) {
        Write-Log 'The GitHub check is still running - try again in a few seconds.' $colAmber
        return $false
    }
    Read-UI
    Save-Settings
    Apply-Env
    return $true
}

function New-Steps { return ,(New-Object System.Collections.ArrayList) }

function Run-Full {
    if (-not (Begin-Action)) { return }
    $l = New-Steps
    Add-SyncSteps $l; Add-TomlStep $l; Add-BuildSteps $l $true; Add-ValidateStep $l $true; Add-ShaderSteps $l; Add-LaunchStep $l
    Start-Pipeline 'Full setup' $l
}
function Run-Shaders {
    if (-not (Begin-Action)) { return }
    $l = New-Steps
    Add-TomlStep $l; Add-BuildSteps $l $false; Add-ValidateStep $l $true; Add-ShaderSteps $l
    Start-Pipeline 'Pre-compile shaders and pipelines' $l
}
function Run-Sync {
    if (-not (Begin-Action)) { return }
    $l = New-Steps
    Add-SyncSteps $l; Add-TomlStep $l; Add-BuildSteps $l $true; Add-ValidateStep $l $false
    Start-Pipeline 'Update from GitHub and build' $l
}
function Run-Launch {
    if (-not (Begin-Action)) { return }
    $l = New-Steps
    Add-TomlStep $l; Add-BuildSteps $l $false; Add-ValidateStep $l $true; Add-LaunchStep $l
    Start-Pipeline 'Launch game' $l
}
function Run-Zip([string]$zipPath) {
    if (-not (Begin-Action)) { return }
    $S.ZipPath = $zipPath
    $l = New-Steps
    Add-ZipSteps $l; Add-TomlStep $l; Add-BuildSteps $l $false; Add-ValidateStep $l $false
    $n = $l.Count
    $l[$n - 3].Skip = { $false }
    $l[$n - 2].Skip = { $false }
    Start-Pipeline 'Update from ZIP and build' $l
}
function Run-Migrate {
    if (-not (Begin-Action)) { return }
    $l = New-Steps
    Add-MigrateSteps $l
    Start-Pipeline 'Move old cache and data to the new folders' $l
}
function Run-Check {
    if ($S.Running) { return }
    if (-not (Begin-Action)) { return }
    if (-not $HaveGit) { Write-Log 'git is not installed.' $colAmber; return }
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptDir '.git'))) {
        Write-Log 'This folder is not linked to GitHub yet. Press "Sync + Build" to link it.' $colAmber
        return
    }
    Start-BgFetch $true
}

# ------------------------------------------------------------------
# Live status (processes + cache scan)
# ------------------------------------------------------------------
function Refresh-Procs {
    $now = Get-Date
    $dt = ($now - $S.ProcT).TotalSeconds
    if ($dt -lt 0.5) { $dt = 0.5 }
    $S.ProcT = $now
    $cores = [Environment]::ProcessorCount
    $names = @('victory', 'cargo', 'rustc', 'git', 'robocopy')
    $gameBase = [IO.Path]::GetFileNameWithoutExtension([string]$Cfg.GameExe)
    if ($gameBase) { $names += $gameBase }
    $procs = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    $parts = New-Object System.Collections.ArrayList
    $S.VicRun = $false; $S.CargoRun = $false; $S.GitRun = $false
    foreach ($g in ($procs | Group-Object Name)) {
        $cd = 0.0; $mem = [long]0
        foreach ($p in $g.Group) {
            $cur = 0.0
            try { $cur = $p.TotalProcessorTime.TotalSeconds } catch {}
            if ($S.PrevCpu.ContainsKey($p.Id)) { $cd += ($cur - $S.PrevCpu[$p.Id]) }
            $S.PrevCpu[$p.Id] = $cur
            try { $mem += $p.WorkingSet64 } catch {}
        }
        $pct = [int][math]::Round(100 * $cd / $dt / $cores)
        if ($pct -lt 0) { $pct = 0 }
        [void]$parts.Add(('{0} x{1}  CPU {2}%  RAM {3:N0} MB' -f $g.Name, $g.Count, $pct, ($mem / 1MB)))
        if ($g.Name -eq 'victory') { $S.VicRun = $true }
        if ($g.Name -eq 'cargo' -or $g.Name -eq 'rustc') { $S.CargoRun = $true }
        if ($g.Name -eq 'git') { $S.GitRun = $true }
    }
    $ids = @($procs | ForEach-Object { $_.Id })
    foreach ($k in @($S.PrevCpu.Keys)) { if ($ids -notcontains $k) { $S.PrevCpu.Remove($k) } }
    if ($parts.Count -eq 0) { $lblProc.Text = 'Processes: none of victory / cargo / rustc / git running' }
    else { $lblProc.Text = 'Processes: ' + ($parts -join '   |   ') }
}

$HwScript = @'
$cpu = $null; $mhz = $null; $gpu = $null; $memUsed = $null; $memTot = $null
$gclk = $null; $temp = $null; $name = $null
$ramUsed = $null; $ramTot = $null
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $ramTot = $os.TotalVisibleMemorySize / 1MB
    $ramUsed = ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB
} catch {}
try {
    $c = (Get-Counter -Counter '\Processor Information(_Total)\% Processor Utility', '\Processor Information(_Total)\% Processor Performance', '\Processor Information(_Total)\Processor Frequency' -ErrorAction Stop).CounterSamples
    $util = ($c | Where-Object { $_.Path -like '*% processor utility' }).CookedValue
    $perf = ($c | Where-Object { $_.Path -like '*% processor performance' }).CookedValue
    $freq = ($c | Where-Object { $_.Path -like '*processor frequency' }).CookedValue
    if ($null -ne $util) { $cpu = [int][math]::Min(100, [math]::Round($util)) }
    if ($freq -and $perf) { $mhz = [int]($freq * $perf / 100) }
} catch {}
$ctemp = $null
try {
    $tz = (Get-Counter -Counter '\Thermal Zone Information(*)\Temperature' -ErrorAction Stop).CounterSamples
    $mxT = 0.0
    foreach ($z in $tz) {
        $c0 = [double]$z.CookedValue - 273.15
        if ($c0 -gt $mxT -and $c0 -lt 125) { $mxT = $c0 }
    }
    if ($mxT -gt 0) { $ctemp = [int][math]::Round($mxT) }
} catch {}
if ($null -eq $ctemp) {
    try {
        $zz = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
        $mxT = 0.0
        foreach ($z in $zz) {
            $c0 = ([double]$z.CurrentTemperature / 10.0) - 273.15
            if ($c0 -gt $mxT -and $c0 -lt 125) { $mxT = $c0 }
        }
        if ($mxT -gt 0) { $ctemp = [int][math]::Round($mxT) }
    } catch {}
}
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    try {
        $o = & nvidia-smi '--query-gpu=name,utilization.gpu,memory.used,memory.total,clocks.sm,temperature.gpu' '--format=csv,noheader,nounits' 2>$null
        $p = (@($o)[0]) -split ',\s*'
        $name = $p[0]
        $gpu = [int]$p[1]
        $memUsed = [double]$p[2] / 1024
        $memTot = [double]$p[3] / 1024
        $gclk = [int]$p[4]
        $temp = [int]$p[5]
    } catch {}
}
if ($null -eq $gpu) {
    try {
        $g = (Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples
        $by = @{}
        foreach ($s in $g) {
            if ($s.InstanceName -match 'luid_(0x[0-9a-f]+_0x[0-9a-f]+)_phys_\d+_eng_\d+_engtype_(\w+)$') {
                $key = $Matches[1] + '/' + $Matches[2]
                if (-not $by.ContainsKey($key)) { $by[$key] = 0.0 }
                $by[$key] += $s.CookedValue
            }
        }
        $mx = 0.0
        foreach ($k in $by.Keys) { if ($by[$k] -gt $mx) { $mx = $by[$k] } }
        $gpu = [int][math]::Min(100, [math]::Round($mx))
    } catch {}
    try {
        $m = (Get-Counter -Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
        $sum = 0.0
        foreach ($s in $m) { $sum += $s.CookedValue }
        $memUsed = $sum / 1GB
    } catch {}
    try { $name = (Get-CimInstance Win32_VideoController | Select-Object -First 1).Name } catch {}
}
[pscustomobject]@{ CpuPct = $cpu; CpuMHz = $mhz; GpuPct = $gpu; GpuMemGB = $memUsed; GpuMemTotGB = $memTot; GpuName = $name; GpuClk = $gclk; GpuTemp = $temp; CpuTemp = $ctemp; RamUsedGB = $ramUsed; RamTotGB = $ramTot }
'@

function Start-Hw {
    if ($S.HwAsync) { return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($HwScript)
    $S.HwPS = $ps
    $S.HwAsync = $ps.BeginInvoke()
}

function Apply-Hw {
    if (-not $S.HwAsync) { return }
    if (-not $S.HwAsync.IsCompleted) { return }
    $res = @()
    try { $res = @($S.HwPS.EndInvoke($S.HwAsync)) } catch {}
    try { $S.HwPS.Dispose() } catch {}
    $S.HwAsync = $null
    $S.HwPS = $null
    if ($res.Count -eq 0) { return }
    $h = $res[0]
    $parts = New-Object System.Collections.ArrayList
    if ($null -ne $h.CpuPct) {
        $t = 'CPU ' + $h.CpuPct + '%'
        if ($h.CpuMHz) { $t += '   ' + ('{0:N2}' -f ($h.CpuMHz / 1000)) + ' GHz' }
        if ($h.CpuTemp) { $t += '   ' + $h.CpuTemp + ' C' }
        [void]$parts.Add($t)
    } else { [void]$parts.Add('CPU n/a') }
    if ($null -ne $h.RamUsedGB -and $h.RamTotGB) {
        $rp = [int][math]::Round(100 * $h.RamUsedGB / $h.RamTotGB)
        [void]$parts.Add('RAM ' + ('{0:N1}' -f $h.RamUsedGB) + ' / ' + ('{0:N0}' -f $h.RamTotGB) + ' GB (' + $rp + '%)')
    } else { [void]$parts.Add('RAM n/a') }
    if ($null -ne $h.GpuPct) {
        $t = 'GPU ' + $h.GpuPct + '%'
        if ($null -ne $h.GpuMemGB) {
            $m = '{0:N1}' -f $h.GpuMemGB
            $t += '   VRAM ' + $m
            if ($h.GpuMemTotGB) { $t += ' / ' + ('{0:N0}' -f $h.GpuMemTotGB) }
            $t += ' GB'
        }
        if ($h.GpuClk) { $t += '   ' + $h.GpuClk + ' MHz' }
        if ($h.GpuTemp) { $t += '   ' + $h.GpuTemp + ' C' }
        if ($h.GpuName) { $t += '   (' + $h.GpuName + ')' }
        [void]$parts.Add($t)
    } else { [void]$parts.Add('GPU n/a') }
    $lblHw.Text = ($parts -join '      |      ')
    $S.Hw = $h
}

function Start-Scan {
    if ($S.ScanAsync) { return }
    $paths = @(
        @{ Tag = 'DXIL';  Path = $Cfg.CacheDir },
        @{ Tag = 'D3D12'; Path = (Join-Path $env:LOCALAPPDATA 'D3DSCache') }
    )
    $ps = [powershell]::Create()
    [void]$ps.AddScript($ScanScript).AddArgument($paths)
    $S.ScanPS = $ps
    $S.ScanAsync = $ps.BeginInvoke()
}

function Apply-Scan {
    if (-not $S.ScanAsync) { return }
    if (-not $S.ScanAsync.IsCompleted) { return }
    $res = @()
    try { $res = @($S.ScanPS.EndInvoke($S.ScanAsync)) } catch {}
    try { $S.ScanPS.Dispose() } catch {}
    $S.ScanAsync = $null
    $S.ScanPS = $null
    $all = New-Object System.Collections.ArrayList
    $totSpd = 0.0
    foreach ($r in $res) {
        $tag = [string]$r.Tag
        $rate = ''
        if ($S.Prev.ContainsKey($tag)) {
            $pv = $S.Prev[$tag]
            $dt = ($r.At - $pv.At).TotalSeconds
            if ($dt -lt 0.5) { $dt = 0.5 }
            $totSpd = $totSpd + [math]::Max(0.0, (($r.Bytes - $pv.Bytes) / 1MB / $dt))
            $rate = ('    {0:N1} files/s   {1:N2} MB/s' -f (($r.Files - $pv.Files) / $dt), (($r.Bytes - $pv.Bytes) / 1MB / $dt))
        }
        if ($tag -eq 'DXIL') {
            $active = ($S.Running -and ($S.StepName -like 'Pre-compile*'))
            if (-not $active) { $S.SpeedBase = $null; $S.SpeedTxt = '' }
            elseif ($null -eq $S.SpeedBase) { $S.SpeedBase = [long]$r.Files; $S.SpeedT = $r.At }
            else {
                $el = ($r.At - $S.SpeedT).TotalSeconds
                if ($el -gt 3) { $S.SpeedTxt = ('    avg {0:N1}/s' -f (($r.Files - $S.SpeedBase) / $el)) }
            }
            $rate = $rate + $S.SpeedTxt
            $S.LastDx = [long]$r.Files
            $S.FracFiles = $null
            $exp = [double]$Cfg.ExpectedFiles
            if ($active -and $null -ne $S.SpeedBase -and $exp -gt $S.SpeedBase) {
                $S.FracFiles = [math]::Max(0.0, [math]::Min(1.0, ($r.Files - $S.SpeedBase) / ($exp - $S.SpeedBase)))
            }
        }
        $S.Prev[$tag] = @{ Files = $r.Files; Bytes = $r.Bytes; At = $r.At }
        if ($null -eq $S.CacheV) { $S.CacheV = @{} }
        $S.CacheV[$tag] = @{ Files = [long]$r.Files; MB = [double]($r.Bytes / 1MB); Rate = $rate.Trim() }
        $txt = ('{0} cache: {1:N0} files, {2:N1} MB{3}' -f $tag, $r.Files, ($r.Bytes / 1MB), $rate)
        if ($tag -eq 'DXIL') { $lblDx.Text = $txt } else { $lblD3.Text = $txt }
        foreach ($e in $r.Recent) { [void]$all.Add(@{ Tag = $tag; Time = $e[0]; Len = $e[1]; Path = [string]$e[2]; Root = [string]$r.Root }) }
    }
    $S.TotSpd = $totSpd
    $now = Get-Date
    $sorted = @($all | Sort-Object { $_.Time } -Descending | Select-Object -First 4)
    $S.Age = $null
    if ($sorted.Count -gt 0) { $S.Age = [int](($now - $sorted[0].Time).TotalSeconds) }
    $feed = New-Object System.Collections.ArrayList
    foreach ($e in $sorted) {
        $ago = [int](($now - $e.Time).TotalSeconds)
        $agoTxt = [string]$ago + 's ago'
        if ($ago -lt 3) { $agoTxt = 'just now' }
        elseif ($ago -ge 3600) { $agoTxt = [string][int]($ago / 3600) + 'h ago' }
        elseif ($ago -ge 120) { $agoTxt = [string][int]($ago / 60) + 'm ago' }
        $kind = 'Shader'
        if ($e.Tag -ne 'DXIL') { $kind = 'Pipeline' }
        $leaf = [IO.Path]::GetFileName($e.Path)
        $short = $leaf
        if ($leaf.Length -gt 84) { $short = $leaf.Substring(0, 8) + '...' + $leaf.Substring($leaf.Length - 60) }
        $rel = $e.Path
        if ($e.Root -and $e.Path.StartsWith($e.Root, [StringComparison]::OrdinalIgnoreCase)) { $rel = $e.Path.Substring($e.Root.Length).TrimStart('\') }
        $len = [double]$e.Len
        if ($len -le 0) { $sz = 'starting' }
        elseif ($len -ge 1GB) { $sz = ('{0:N2} GB' -f ($len / 1GB)) }
        elseif ($len -ge 1MB) { $sz = ('{0:N1} MB' -f ($len / 1MB)) }
        else { $sz = ('{0:N0} KB' -f ($len / 1KB)) }
        [void]$feed.Add(@{ Age = $agoTxt; Kind = $kind; Size = $sz; Name = $short; Leaf = $leaf; Rel = $rel; Full = $e.Path; Fresh = ($ago -lt 5) })
    }
    $S.Feed = $feed
    $fb = @{ Pct = 0.0; Text = 'idle'; Active = $false; Indet = $false }
    if ($sorted.Count -gt 0) {
        $n0 = $sorted[0]
        $kind0 = 'Shader'
        if ($n0.Tag -ne 'DXIL') { $kind0 = 'Pipeline' }
        if ($null -eq $S.MaxLen) { $S.MaxLen = @{ Shader = [double]0; Pipeline = [double]0 } }
        foreach ($x in $sorted) {
            $kx = 'Shader'
            if ($x.Tag -ne 'DXIL') { $kx = 'Pipeline' }
            if ([double]$x.Len -gt $S.MaxLen[$kx]) { $S.MaxLen[$kx] = [double]$x.Len }
        }
        $len0 = [double]$n0.Len
        $age0 = ($now - $n0.Time).TotalSeconds
        if (-not $S.FilePrev -or $S.FilePrev.Path -ne $n0.Path -or $len0 -gt $S.FilePrev.Len) { $S.FilePrev = @{ Path = $n0.Path; Len = $len0; At = $now } }
        $ts = [double]$S.TotSpd
        if ($ts -ge 1.0) { $spd = ('{0:N1} MB/s' -f $ts) } else { $spd = ('{0:N0} KB/s' -f ($ts * 1024)) }
        $mx = [double]$S.MaxLen[$kind0]
        $pc = 0.0
        if ($mx -gt 0 -and $len0 -gt 0) { $pc = [math]::Min(99.0, 100.0 * $len0 / $mx) }
        $szt = 'starting'
        if ($len0 -ge 1GB) { $szt = ('{0:N2} GB' -f ($len0 / 1GB)) } elseif ($len0 -ge 1MB) { $szt = ('{0:N1} MB' -f ($len0 / 1MB)) } elseif ($len0 -gt 0) { $szt = ('{0:N0} KB' -f ($len0 / 1KB)) }
        if ($age0 -lt 15) {
            $fb.Active = $true
            $fb.Pct = $pc
            if ($mx -gt 0 -and $len0 -ge (0.1 * $mx) -and $len0 -lt (0.98 * $mx)) {
                $fb.Text = ('{0}   |   {1}   |   ~{2:N0}%' -f $szt, $spd, $pc)
            } else {
                $fb.Indet = $true
                $fb.Text = ('{0}   |   {1}   |   writing...' -f $szt, $spd)
            }
        } else {
            $fb.Text = 'idle'
        }
    }
    $S.FileBar = $fb
    if ($fb.Active) { $lblEtaFile.Text = 'writing'; $lblEtaFile.ForeColor = $thCyan } else { $lblEtaFile.Text = 'idle'; $lblEtaFile.ForeColor = $colGray }
    $barFile.Invalidate()
    $pnlFeed.Invalidate()
}

function Update-Labels {
    if ($S.Running) {
        $el = Fmt-Time ((Get-Date) - $S.Start)
        $lblStep.Text = 'Step ' + $S.Done + '/' + $S.Total + '   ' + $S.StepName + '    ' + $el
    } elseif ($S.Bg) {
        $lblStep.Text = 'Checking GitHub...'
    } else {
        $lblStep.Text = 'Idle - ready'
    }
    $want = 'Sync + Build'
    if ($S.Behind -gt 0) { $want = 'UPDATE + Build' }
    if ($btnSync.Text -ne $want) { $btnSync.Text = $want }
    $status = 'nothing heavy is running right now'
    if ($S.VicRun) {
        if ($null -eq $S.Age) { $status = 'victory.exe is running - no cache file written yet in the last 15 minutes' }
        elseif ($S.Age -gt 90) { $status = 'victory.exe is running but wrote nothing for ' + $S.Age + 's (big shader, or stuck)' }
        else { $status = 'victory.exe is running and writing files (last one ' + $S.Age + 's ago)' }
    } elseif ($S.Running -and $S.StepName -like 'Pre-compile*') {
        $status = 'WARNING: compiling step is active but victory.exe is not running (starting, finished, or between retry passes)'
    } elseif ($S.CargoRun) { $status = 'cargo is compiling the Rust code' }
    elseif ($S.GitRun) { $status = 'git is working' }
    $lblStatus.Text = 'Status: ' + $status
    if ($S.Runner) {
        $t = [regex]::Replace([string]$S.Runner.Transient, $S.AnsiPat, '')
        if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
        $lblLive.Text = $t
    }
    if ($tt.GetToolTip($lblRepo) -ne $lblRepo.Text) { $tt.SetToolTip($lblRepo, $lblRepo.Text) }
    if ($tt.GetToolTip($lblStatus) -ne $lblStatus.Text) { $tt.SetToolTip($lblStatus, $lblStatus.Text) }
    if ($tt.GetToolTip($lblHw) -ne $lblHw.Text) { $tt.SetToolTip($lblHw, $lblHw.Text) }
}

function Drain($runner) {
    $line = $null
    $n = 0
    if ($runner.Lines.Count -gt 3000) {
        $skip = 0
        while ($runner.Lines.Count -gt 800 -and $runner.Lines.TryDequeue([ref]$line)) { $skip++ }
        Write-Log ('  ... skipped ' + $skip + ' lines of output ...') $colGray
    }
    while ($n -lt 250 -and $runner.Lines.TryDequeue([ref]$line)) {
        $n++
        $t = [regex]::Replace([string]$line, $S.AnsiPat, '')
        Parse-Progress $t
        $c = $null
        if ($t -match '(?i)\b(error|failed|panic)') { $c = $colRed }
        elseif ($t -match '(?i)\bwarn') { $c = $colAmber }
        Write-Log ('  ' + $t) $c
    }
}

# ------------------------------------------------------------------
# Music (built-in original synthwave loop, or a file you pick)
# ------------------------------------------------------------------
function Music-UI {
    if ($S.MusicWait) { $btnMusic.Text = 'Making music...'; $btnMusic.BackColor = $thBtnHot }
    elseif ($S.MusicOn) { $btnMusic.Text = 'Music: ON'; $btnMusic.BackColor = $thPink }
    else { $btnMusic.Text = 'Music: OFF'; $btnMusic.BackColor = $thBtn }
}

function Music-Idx {
    $i = 0
    try { $i = [int]$Cfg.MusicTrack } catch { $i = 0 }
    if ($i -lt 0 -or $i -ge $MusicTracks.Count) { $i = 0 }
    return $i
}

function Music-Start {
    $idx = Music-Idx
    $src = $MusicTracks[$idx]
    $builtin = $true
    if ($Cfg.MusicFile -and (Test-Path -LiteralPath $Cfg.MusicFile)) { $src = [string]$Cfg.MusicFile; $builtin = $false }
    if ($builtin -and [Synth]::Ready -le $idx) {
        $S.MusicWait = $true
        Music-UI
        return
    }
    $S.MusicWait = $false
    try {
        if (-not $S.Player) {
            Add-Type -AssemblyName PresentationCore
            $S.Player = New-Object System.Windows.Media.MediaPlayer
        }
        $S.Player.Open([Uri]$src)
        $S.Player.Volume = [double]($Cfg.MusicVol / 100.0)
        $S.Player.Play()
        $S.MusicOn = $true
    } catch {
        Write-Log ('Could not play music: ' + $_.Exception.Message) $colAmber
        $S.MusicOn = $false
    }
    Music-UI
}

function Music-Stop {
    try { if ($S.Player) { $S.Player.Stop() } } catch {}
    $S.MusicOn = $false
    $S.MusicWait = $false
    Music-UI
}

function Music-Toggle {
    if ($S.MusicOn -or $S.MusicWait) { Music-Stop; $Cfg.MusicOn = $false }
    else { Music-Start; $Cfg.MusicOn = [bool]($S.MusicOn -or $S.MusicWait) }
    Save-Settings
}

function Music-Pick {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Audio files|*.mp3;*.wav;*.wma;*.m4a;*.aac|All files (*.*)|*.*'
    if ($Cfg.MusicFile -and (Test-Path -LiteralPath $Cfg.MusicFile)) { $d.FileName = [string]$Cfg.MusicFile }
    if ($d.ShowDialog() -ne 'OK') { return }
    $Cfg.MusicFile = $d.FileName
    Save-Settings
    Write-Log ('Music: ' + $d.FileName) $colGray
    if ($S.MusicOn -or $S.MusicWait) { Music-Stop; Music-Start; $Cfg.MusicOn = [bool]($S.MusicOn -or $S.MusicWait); Save-Settings }
}

function Music-Select($i) {
    $Cfg.MusicTrack = [int]$i
    $Cfg.MusicFile = ''
    Save-Settings
    Write-Log ('Music: ' + $MusicNames[[int]$i]) $colGray
    if ($S.MusicOn -or $S.MusicWait) { Music-Stop; Music-Start; $Cfg.MusicOn = [bool]($S.MusicOn -or $S.MusicWait); Save-Settings }
}

function Music-Reset {
    $Cfg.MusicFile = ''
    Save-Settings
    Write-Log 'Music: back to the built-in tracks' $colGray
    if ($S.MusicOn) { Music-Stop; Music-Start }
}

function Music-Tick {
    if ($S.MusicWait) {
        if (([Synth]::Ready -gt (Music-Idx)) -or ($Cfg.MusicFile -and (Test-Path -LiteralPath $Cfg.MusicFile))) { Music-Start }
        return
    }
    if ($S.MusicOn -and $S.Player) {
        try {
            if ($S.Player.NaturalDuration.HasTimeSpan) {
                $dur = $S.Player.NaturalDuration.TimeSpan.TotalSeconds
                if ($dur -gt 1 -and $S.Player.Position.TotalSeconds -ge ($dur - 0.2)) {
                    $S.Player.Position = [TimeSpan]::Zero
                    $S.Player.Play()
                }
            }
        } catch {}
    }
}

function Set-DoubleBuffer($c) {
    $p = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $p.SetValue($c, $true, $null)
}

function Paint-Bar($g, $rect, [double]$pct, [bool]$indet, [string]$text) {
    if ($rect.Width -lt 6 -or $rect.Height -lt 6) { return }
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $w = $rect.Width - 1
    $h = $rect.Height - 1
    $bg = New-Object System.Drawing.SolidBrush($thInput)
    $g.FillRectangle($bg, 0, 0, $w, $h)
    $bg.Dispose()
    if ($indet) {
        $bw = [int]($w * 0.3)
        $x = [int](($S.Ticks * 28) % ($w + $bw)) - $bw
        $x0 = [math]::Max(0, $x)
        $x1 = [math]::Min($w, $x + $bw)
        if ($x1 -gt $x0) {
            $br = New-Object System.Drawing.SolidBrush($thPink)
            $g.FillRectangle($br, $x0, 0, ($x1 - $x0), $h)
            $br.Dispose()
        }
    } elseif ($pct -gt 0) {
        $fw = [int]($w * [math]::Min(100.0, $pct) / 100.0)
        if ($fw -ge 2) {
            $gr = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Rectangle(0, 0, $fw, $h)), $thOrange, $thPink, [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
            $g.FillRectangle($gr, 0, 0, $fw, $h)
            $gr.Dispose()
        }
    }
    $pen = New-Object System.Drawing.Pen($thPurple)
    $g.DrawRectangle($pen, 0, 0, $w, $h)
    $pen.Dispose()
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'
    $sf.LineAlignment = 'Center'
    $fnt = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(170, 0, 0, 0))
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $r1 = New-Object System.Drawing.RectangleF(1, 1, $rect.Width, $rect.Height)
    $r2 = New-Object System.Drawing.RectangleF(0, 0, $rect.Width, $rect.Height)
    $g.DrawString($text, $fnt, $shadow, $r1, $sf)
    $g.DrawString($text, $fnt, $white, $r2, $sf)
    $sf.Dispose(); $fnt.Dispose(); $shadow.Dispose(); $white.Dispose()
}

function Update-Progress {
    if (-not $S.Running) { return }
    $now = Get-Date
    $st = $S.Cur
    $stepEl = 0.0
    if ($S.StepStart) { $stepEl = ($now - $S.StepStart).TotalSeconds }
    $curW = 0.0
    $f = $null
    $est = $false
    $slow = $false
    if ($S.Runner -and $st) {
        $curW = [double]$st.Weight
        $learn = 0.0
        if ($st.Learn) {
            $learn = [double]$Cfg[$st.Learn]
            $jb = Get-Jobs
            if ($st.JobsUsed) { $jb = [int]$st.JobsUsed }
            if ($st.Learn -eq 'LastShaderWork') { $learn = $learn / [math]::Max(1, $jb) }
        }
        if ($null -ne $S.StepFrac) { $f = [double]$S.StepFrac }
        elseif ($null -ne $S.FracFiles -and [double]$S.FracFiles -ge 0.02) { $f = [double]$S.FracFiles }
        elseif ($learn -gt 0) {
            $f = [math]::Min(0.97, $stepEl / $learn)
            $est = $true
            if ($stepEl -gt $learn) { $slow = $true }
        }
    }
    $mark = ''
    if ($est) { $mark = '~' }
    $stepElTxt = Fmt-Time ([TimeSpan]::FromSeconds($stepEl))
    $stepEta = 'ETA --:--:--'
    $overEta = 'ETA --:--:--'
    $stepHas = $false
    $overHas = $false
    if ($S.Runner) {
        if ($null -ne $f) {
            $S.StepIndet = $false
            $S.StepPct = [math]::Round($f * 100.0, 0)
            $S.StepText = 'Step ' + $mark + [int]$S.StepPct + '%'
            if ($slow) { $stepEta = 'ETA overdue' }
            elseif ($f -gt 0.01 -and $stepEl -gt 5) {
                $eta = [math]::Min($stepEl * (1.0 - $f) / $f, 359999)
                $stepEta = 'ETA ' + $mark + (Fmt-Time ([TimeSpan]::FromSeconds($eta)))
                $stepHas = $true
            }
        } else {
            $S.StepIndet = $true
            $S.StepPct = 0.0
            $S.StepText = 'Step: working  ' + $stepElTxt
        }
    } else {
        $S.StepIndet = $false
        $S.StepPct = 0.0
        $S.StepText = 'Step'
    }
    $tot = [double]$S.WeightTotal
    if ($tot -le 0) { $tot = 1.0 }
    $ff = 0.0
    if ($null -ne $f) { $ff = $f }
    $frac = ($S.WeightDone + ($curW * $ff)) / $tot
    $frac = [math]::Max(0.0, [math]::Min(1.0, $frac))
    $S.OverallPct = [math]::Round($frac * 100.0, 0)
    $txt = 'Overall ' + [int]$S.OverallPct + '%'
    if ($null -ne $f -and $f -gt 0.01 -and $stepEl -gt 5 -and $curW -gt 0 -and -not $slow) {
        $perW = $stepEl / ($curW * $f)
        $remW = ($curW * (1.0 - $f)) + ($tot - $S.WeightDone - $curW)
        $eta = [math]::Min($perW * [math]::Max(0.0, $remW), 359999)
        $overEta = 'ETA ' + $mark + (Fmt-Time ([TimeSpan]::FromSeconds($eta)))
        $overHas = $true
    } else {
        $txt += '   ' + (Fmt-Time ((Get-Date) - $S.Start)) + ' elapsed'
        if ($slow) { $overEta = 'ETA overdue' }
    }
    $S.OverallText = $txt
    $lblEtaStep.Text = $stepEta
    $lblEtaOverall.Text = $overEta
    if ($stepHas) { $lblEtaStep.ForeColor = $thCyan } else { $lblEtaStep.ForeColor = $colGray }
    if ($overHas) { $lblEtaOverall.ForeColor = $thCyan } else { $lblEtaOverall.ForeColor = $colGray }
    $barOverall.Invalidate()
    $barStep.Invalidate()
}

function Tick {
    $S.Ticks = $S.Ticks + 1
    if ($S.Runner) {
        Drain $S.Runner
        if ($S.Runner.Exited -and $S.Runner.Lines.IsEmpty) { Handle-Exit }
    }
    if ($S.Bg) {
        $d = $null
        while ($S.Bg.Lines.TryDequeue([ref]$d)) { }
        if ($S.Bg.Exited) { Bg-Done }
    }
    Apply-Scan
    Apply-Hw
    if ($S.Runner) {
        $tr = [string]$S.Runner.Transient
        if ($tr) { Parse-Progress ([regex]::Replace($tr, $S.AnsiPat, '')) }
    }
    Update-Progress
    if (($S.Ticks % 4) -eq 0) {
        Refresh-Procs
        Start-Scan
        Start-Hw
    }
    Update-Labels
    if ($S.FileBar -and $S.FileBar.Active) { $barFile.Invalidate() }
    if (($S.Ticks % 2) -eq 0) { $pnlTiles.Invalidate(); $pnlCache.Invalidate() }
}

function Tick-Guard {
    try { Tick }
    catch {
        $m = $_.Exception.Message
        if ($S.LastErr -ne $m) { $S.LastErr = $m; Write-Log ('[internal error] ' + $m) $colRed }
    }
}

# ------------------------------------------------------------------
# UI
# ------------------------------------------------------------------
function New-Label($text, $x, $y, $w, $h) {
    $c = New-Object System.Windows.Forms.Label
    $c.AutoSize = $false
    $c.UseMnemonic = $false
    $c.AutoEllipsis = $true
    $c.Text = $text
    $c.SetBounds($x, $y, $w, [math]::Max($h, 22))
    $c.TextAlign = 'MiddleLeft'
    return $c
}

function New-Text($text, $x, $y, $w) {
    $c = New-Object System.Windows.Forms.TextBox
    $c.Text = [string]$text
    $c.SetBounds($x, $y, $w, 23)
    return $c
}

function New-Btn($text, $x, $y, $w, $h) {
    $c = New-Object System.Windows.Forms.Button
    $c.Text = $text
    $c.SetBounds($x, $y, $w, $h)
    return $c
}

function Browse-Folder($tb) {
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($tb.Text -and (Test-Path -LiteralPath $tb.Text)) { $d.SelectedPath = $tb.Text }
    if ($d.ShowDialog() -eq 'OK') { $tb.Text = $d.SelectedPath }
}

function Browse-File($tb, [string]$filter) {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = $filter
    if ($tb.Text -and (Test-Path -LiteralPath $tb.Text -PathType Leaf)) { $d.FileName = $tb.Text }
    if ($d.ShowDialog() -eq 'OK') { $tb.Text = $d.FileName }
}

function Choose-Zip {
    if ($S.Running) { return }
    $r = [System.Windows.Forms.MessageBox]::Show("Update the source from a ZIP file?`r`n`r`nYes = download the latest ZIP from GitHub`r`nNo = pick a ZIP file on this computer`r`nCancel = do nothing", 'Update from ZIP', 'YesNoCancel', 'Question')
    if ($r -eq 'Yes') { Run-Zip '' }
    elseif ($r -eq 'No') {
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Filter = 'ZIP files (*.zip)|*.zip|All files (*.*)|*.*'
        if ($Cfg.ZipFile -and (Test-Path -LiteralPath $Cfg.ZipFile)) { $d.FileName = [string]$Cfg.ZipFile }
        if ($d.ShowDialog() -eq 'OK') { $Cfg.ZipFile = $d.FileName; Run-Zip $d.FileName }
    }
}

function Browse-GameFile {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Game file (*.exe)|*.exe|All files (*.*)|*.*'
    if ($txtGame.Text -and (Test-Path -LiteralPath $txtGame.Text -PathType Container)) { $d.InitialDirectory = $txtGame.Text }
    if ($d.ShowDialog() -eq 'OK') {
        $txtGame.Text = [IO.Path]::GetDirectoryName($d.FileName)
        $txtExe.Text  = [IO.Path]::GetFileName($d.FileName)
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Hyphen Manager'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(950, 906)
$form.MinimumSize = New-Object System.Drawing.Size(840, 680)
$form.AutoScaleMode = 'None'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$tt = New-Object System.Windows.Forms.ToolTip

# ---- Theme: neon sunset ----
$thBg     = [System.Drawing.Color]::FromArgb(18, 9, 34)
$thPanel  = [System.Drawing.Color]::FromArgb(32, 16, 56)
$thInput  = [System.Drawing.Color]::FromArgb(12, 6, 24)
$thText   = [System.Drawing.Color]::FromArgb(250, 238, 250)
$thPink   = [System.Drawing.Color]::FromArgb(255, 60, 140)
$thOrange = [System.Drawing.Color]::FromArgb(255, 140, 50)
$thPurple = [System.Drawing.Color]::FromArgb(140, 70, 230)
$thBtn    = [System.Drawing.Color]::FromArgb(54, 28, 92)
$thBtnHot = [System.Drawing.Color]::FromArgb(84, 44, 140)
$thCyan   = [System.Drawing.Color]::FromArgb(0, 224, 255)

function Apply-Theme($parent) {
    foreach ($c in $parent.Controls) {
        if ($c -is [System.Windows.Forms.GroupBox]) {
            $c.FlatStyle = 'Flat'; $c.BackColor = $thPanel; $c.ForeColor = $thPink
        } elseif ($c -is [System.Windows.Forms.TextBox]) {
            $c.BackColor = $thInput; $c.ForeColor = $thText; $c.BorderStyle = 'FixedSingle'
        } elseif ($c -is [System.Windows.Forms.ComboBox]) {
            $c.BackColor = $thInput; $c.ForeColor = $thText; $c.FlatStyle = 'Flat'
        } elseif ($c -is [System.Windows.Forms.NumericUpDown]) {
            $c.BackColor = $thInput; $c.ForeColor = $thText
        } elseif ($c -is [System.Windows.Forms.Button]) {
            $c.FlatStyle = 'Flat'
            $c.FlatAppearance.BorderSize = 1
            $c.FlatAppearance.BorderColor = $thPurple
            $c.FlatAppearance.MouseOverBackColor = $thBtnHot
            $c.BackColor = $thBtn; $c.ForeColor = $thText
        } elseif ($c -is [System.Windows.Forms.CheckBox]) {
            $c.ForeColor = $thText
        } elseif ($c -is [System.Windows.Forms.ListBox]) {
            $c.BackColor = $thInput; $c.ForeColor = $thCyan; $c.BorderStyle = 'FixedSingle'
        } elseif ($c -is [System.Windows.Forms.RichTextBox]) {
            $c.BackColor = $thInput; $c.ForeColor = $thText; $c.BorderStyle = 'FixedSingle'
        } elseif ($c -is [System.Windows.Forms.Label]) {
            $c.ForeColor = $thText
        }
        if ($c.Controls.Count -gt 0) { Apply-Theme $c }
    }
}

$body = New-Object System.Windows.Forms.Panel
$body.SetBounds(0, 62, 950, 844)
$body.Anchor = 'Top, Bottom, Left, Right'
$form.Controls.Add($body)

$banner = New-Object System.Windows.Forms.Panel
$banner.SetBounds(0, 0, 950, 62)
$banner.Anchor = 'Top, Left, Right'
$banner.Add_Paint({
    param($sender, $e)
    $r = $sender.ClientRectangle
    if ($r.Width -lt 2 -or $r.Height -lt 2) { return }
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($r, $thOrange, $thPurple, [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
    $blend = New-Object System.Drawing.Drawing2D.ColorBlend(3)
    $blend.Colors = [System.Drawing.Color[]]@($thOrange, $thPink, $thPurple)
    $blend.Positions = [single[]]@(0.0, 0.5, 1.0)
    $br.InterpolationColors = $blend
    $g.FillRectangle($br, $r)
    $br.Dispose()
    $f1 = New-Object System.Drawing.Font('Segoe UI', 22, ([System.Drawing.FontStyle]::Bold -bor [System.Drawing.FontStyle]::Italic))
    $f2 = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 20, 5, 40))
    $white  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $sz1 = $g.MeasureString('HYPHEN', $f1)
    $y1 = [single](($r.Height - $sz1.Height) / 2)
    $g.DrawString('HYPHEN', $f1, $shadow, 17, ($y1 + 3))
    $g.DrawString('HYPHEN', $f1, $white, 14, $y1)
    $sub = 'PC PORT MANAGER  //  SHADER CACHE BUILDER'
    $sz2 = $g.MeasureString($sub, $f2)
    $x2 = 14 + $sz1.Width + 8
    $limit = $r.Width
    try { if ($musicBox) { $limit = $musicBox.Left - 8 } } catch {}
    if (($x2 + $sz2.Width) -gt $limit) { $sub = 'PC PORT MANAGER'; $sz2 = $g.MeasureString($sub, $f2) }
    if (($x2 + $sz2.Width) -le $limit) {
        $g.DrawString($sub, $f2, $white, $x2, [single](($r.Height - $sz2.Height) / 2 + 4))
    }
    $f1.Dispose(); $f2.Dispose(); $shadow.Dispose(); $white.Dispose()
})
$banner.Add_Resize({ $this.Invalidate() })
$form.Controls.Add($banner)

$musicBox = New-Object System.Windows.Forms.Panel
$musicBox.SetBounds(276, 10, 656, 42)
$musicBox.Anchor = 'Top, Right'
$musicBox.BackColor = $thPanel
$btnMusic = New-Btn 'Music: OFF' 8 6 118 30
$btnPick = New-Btn 'Song...' 132 6 70 30
$cmbTrack = New-Object System.Windows.Forms.ComboBox
$cmbTrack.DropDownStyle = 'DropDownList'
$cmbTrack.SetBounds(208, 8, 120, 28)
foreach ($nm in $MusicNames) { [void]$cmbTrack.Items.Add($nm) }
$cmbTrack.SelectedIndex = (Music-Idx)
$btnNext = New-Btn 'Skip >>' 332 6 62 30
$lblVol = New-Label 'Vol' 398 12 28 20
$trkVol = New-Object System.Windows.Forms.TrackBar
$trkVol.SetBounds(426, 8, 66, 30)
$trkVol.Minimum = 0
$trkVol.Maximum = 100
$trkVol.TickStyle = 'None'
$trkVol.Value = [math]::Min(100, [math]::Max(0, [int]$Cfg.MusicVol))
$trkVol.BackColor = $thPanel
$musicBox.Controls.Add($btnMusic)
$musicBox.Controls.Add($btnPick)
$musicBox.Controls.Add($cmbTrack)
$musicBox.Controls.Add($btnNext)
$musicBox.Controls.Add($lblVol)
$musicBox.Controls.Add($trkVol)
$btnRzA = New-Btn 'Drag' 500 6 48 30
$btnRzB = New-Btn 'Fold' 550 6 44 30
$btnRzC = New-Btn 'Panes' 596 6 52 30
$btnRzA.Tag = 'Drag'; $btnRzB.Tag = 'Fold'; $btnRzC.Tag = 'Panes'
foreach ($c in @($btnRzA, $btnRzB, $btnRzC)) { $c.Font = New-Object System.Drawing.Font('Segoe UI', 8.5); $musicBox.Controls.Add($c) }
$tt.SetToolTip($btnRzA, 'Resize mode A: drag the bars between the boxes.')
$tt.SetToolTip($btnRzB, 'Resize mode B: fold boxes away with their arrow button, or drag the corner grips.')
$tt.SetToolTip($btnRzC, 'Resize mode C: two columns side by side (settings and actions on the left, live status and log on the right).')
$banner.Controls.Add($musicBox)
$tt.SetToolTip($btnMusic, 'Turn the music on or off.')
$tt.SetToolTip($btnPick, 'Play your own audio file instead. Right-click to go back to the built-in song.')
$tt.SetToolTip($trkVol, 'Music volume')
$tt.SetToolTip($cmbTrack, 'Choose one of the 5 built-in original tracks.')
$tt.SetToolTip($btnNext, 'Skip to the next built-in track.')

# ---- Settings group ----
$gSet = New-Object System.Windows.Forms.GroupBox
$gSet.Text = 'Settings   (every folder and file can be picked with the buttons on the right)'
$gSet.SetBounds(10, 6, 930, 250)
$gSet.Anchor = 'Top, Left, Right'
$body.Controls.Add($gSet)

# row 1: game folder
$gSet.Controls.Add((New-Label 'Game folder' 8 25 100 20))
$txtGame = New-Text $Cfg.GameDir 116 22 690
$txtGame.Anchor = 'Top, Left, Right'
$gSet.Controls.Add($txtGame)
$btnB1 = New-Btn 'Browse...' 814 21 100 25
$btnB1.Anchor = 'Top, Right'
$btnB1.Tag = $txtGame
$btnB1.Add_Click({ param($sender, $e) Guard { Browse-Folder $sender.Tag } })
$gSet.Controls.Add($btnB1)

# row 2: game file (picking it also fills in the game folder)
$gSet.Controls.Add((New-Label 'Game file' 8 53 100 20))
$txtExe = New-Text $Cfg.GameExe 116 50 690
$txtExe.Anchor = 'Top, Left, Right'
$gSet.Controls.Add($txtExe)
$btnBExe = New-Btn 'Pick file...' 814 49 100 25
$btnBExe.Anchor = 'Top, Right'
$btnBExe.Add_Click({ Guard { Browse-GameFile } })
$gSet.Controls.Add($btnBExe)

# row 3: cache folder
$gSet.Controls.Add((New-Label 'Cache folder' 8 81 100 20))
$txtCache = New-Text $Cfg.CacheDir 116 78 690
$txtCache.Anchor = 'Top, Left, Right'
$gSet.Controls.Add($txtCache)
$btnB2 = New-Btn 'Browse...' 814 77 100 25
$btnB2.Anchor = 'Top, Right'
$btnB2.Tag = $txtCache
$btnB2.Add_Click({ param($sender, $e) Guard { Browse-Folder $sender.Tag } })
$gSet.Controls.Add($btnB2)

# row 4: data folder
$gSet.Controls.Add((New-Label 'Data folder' 8 109 100 20))
$txtData = New-Text $Cfg.DataDir 116 106 690
$txtData.Anchor = 'Top, Left, Right'
$gSet.Controls.Add($txtData)
$btnB3 = New-Btn 'Browse...' 814 105 100 25
$btnB3.Anchor = 'Top, Right'
$btnB3.Tag = $txtData
$btnB3.Add_Click({ param($sender, $e) Guard { Browse-Folder $sender.Tag } })
$gSet.Controls.Add($btnB3)

# row 5: old files folder (source for "Move old files")
$gSet.Controls.Add((New-Label 'Old files folder' 8 137 100 20))
$txtOld = New-Text $Cfg.OldDir 116 134 690
$txtOld.Anchor = 'Top, Left, Right'
$gSet.Controls.Add($txtOld)
$btnB4 = New-Btn 'Browse...' 814 133 100 25
$btnB4.Anchor = 'Top, Right'
$btnB4.Tag = $txtOld
$btnB4.Add_Click({ param($sender, $e) Guard { Browse-Folder $sender.Tag } })
$gSet.Controls.Add($btnB4)

# row 6: repo
$gSet.Controls.Add((New-Label 'GitHub repo' 8 165 100 20))
$txtRepo = New-Text $Cfg.RepoUrl 116 162 798
$txtRepo.Anchor = 'Top, Left, Right'
$gSet.Controls.Add($txtRepo)

# row 7: shader jobs + save
$gSet.Controls.Add((New-Label 'Shader jobs' 8 193 100 20))
$numJobs = New-Object System.Windows.Forms.NumericUpDown
$numJobs.SetBounds(116, 190, 60, 23)
$numJobs.Minimum = 1
$numJobs.Maximum = 128
$numJobs.Value = [decimal][math]::Min(128, [math]::Max(1, [int]$Cfg.Jobs))
$gSet.Controls.Add($numJobs)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.SetBounds(190, 191, 240, 22)
$chkAuto.Text = 'Auto (CPU threads minus 1)'
$chkAuto.Checked = [bool]$Cfg.AutoJobs
$gSet.Controls.Add($chkAuto)

$gSet.Controls.Add((New-Label 'Expected files' 440 193 100 20))
$numExp = New-Object System.Windows.Forms.NumericUpDown
$numExp.SetBounds(544, 190, 100, 23)
$numExp.Minimum = 0
$numExp.Maximum = 5000000
$numExp.ThousandsSeparator = $true
$numExp.Value = [decimal][math]::Min(5000000, [math]::Max(0, [int]$Cfg.ExpectedFiles))
$gSet.Controls.Add($numExp)

$btnSave = New-Btn 'Save settings' 784 189 130 26
$btnSave.Anchor = 'Top, Right'
$gSet.Controls.Add($btnSave)

# row 8: launch program + arguments
$gSet.Controls.Add((New-Label 'Launch program' 8 221 100 20))
$txtProg = New-Text $Cfg.LaunchProg 116 218 300
$gSet.Controls.Add($txtProg)
$btnBProg = New-Btn 'Pick...' 424 217 80 25
$btnBProg.Add_Click({ Guard { Browse-File $txtProg 'Programs (*.exe)|*.exe|All files (*.*)|*.*' } })
$gSet.Controls.Add($btnBProg)
$gSet.Controls.Add((New-Label 'arguments' 512 221 76 20))
$txtArgs = New-Text $Cfg.LaunchArgs 592 218 322
$txtArgs.Anchor = 'Top, Left, Right'
$gSet.Controls.Add($txtArgs)

$tt.SetToolTip($txtProg, '{BIN} = the built victory.exe. Replace it with a full path to run something else.')
$tt.SetToolTip($txtArgs, 'Placeholders: {BIN} = victory.exe   {EXE} = game file   {GAMEDIR} = game folder')
$tt.SetToolTip($btnBExe, 'Pick the game file. The game folder is filled in from it.')
$tt.SetToolTip($txtOld, 'Where the old cache and data live (used by "Move old files").')
$tt.SetToolTip($numExp, 'How many DXIL cache files a finished run ends with (0 = unknown). Used for the % and ETA when the tool prints no progress. Learned automatically after each successful shader run.')

# ---- Actions group ----
$gAct = New-Object System.Windows.Forms.GroupBox
$gAct.Text = 'Actions'
$gAct.SetBounds(10, 262, 930, 112)
$gAct.Anchor = 'Top, Left, Right'
$body.Controls.Add($gAct)

$btnFull = New-Btn 'Full Setup  (sync + build + shaders + launch)' 12 22 400 40
$btnFull.FlatStyle = 'Flat'
$btnFull.BackColor = [System.Drawing.Color]::FromArgb(30, 140, 70)
$btnFull.ForeColor = [System.Drawing.Color]::White
$btnFull.Font = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
$gAct.Controls.Add($btnFull)
$btnShaders = New-Btn 'Compile Shaders Only' 420 22 190 40
$gAct.Controls.Add($btnShaders)
$btnSync = New-Btn 'Sync + Build' 618 22 140 40
$gAct.Controls.Add($btnSync)
$btnLaunch = New-Btn 'Launch Game' 766 22 148 40
$gAct.Controls.Add($btnLaunch)

$btnCheck = New-Btn 'Check for Updates' 12 70 160 30
$gAct.Controls.Add($btnCheck)
$btnCache = New-Btn 'Open Cache Folder' 178 70 160 30
$gAct.Controls.Add($btnCache)
$btnMigrate = New-Btn 'Move old files' 344 70 130 30
$gAct.Controls.Add($btnMigrate)
$btnZip = New-Btn 'Update from ZIP...' 480 70 180 30
$gAct.Controls.Add($btnZip)
$btnClear = New-Btn 'Clear Log' 668 70 90 30
$gAct.Controls.Add($btnClear)
$tt.SetToolTip($btnZip, 'Update the source from a ZIP file (download the latest ZIP from GitHub, or pick one you already have), then build. Your settings and victory.toml are kept.')
$btnStop = New-Btn 'STOP' 814 70 100 30
$btnStop.Anchor = 'Top, Right'
$btnStop.FlatStyle = 'Flat'
$btnStop.BackColor = [System.Drawing.Color]::FromArgb(190, 40, 40)
$btnStop.ForeColor = [System.Drawing.Color]::White
$btnStop.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$btnStop.Enabled = $false
$gAct.Controls.Add($btnStop)

$tt.SetToolTip($btnFull, 'Full Setup (F5): check config, pull the latest code, build, pre-compile shaders and pipelines, then launch.')
$tt.SetToolTip($btnShaders, '(F7) Only pre-compile shaders and D3D12 pipelines (builds first if there is no build yet).')
$tt.SetToolTip($btnSync, '(F6) Pull the latest code from GitHub and build it. Skips work that is already done.')
$tt.SetToolTip($btnLaunch, '(F8) Start the game using the launch program and arguments in Settings.')
$tt.SetToolTip($btnStop, 'Stops the running task and everything it started.')
$tt.SetToolTip($chkAuto, 'Uses (CPU threads - 1) shader jobs instead of the number on the left.')
$chkOpt = New-Object System.Windows.Forms.CheckBox
$chkOpt.SetBounds(652, 191, 130, 22)
$chkOpt.Text = 'Optimized build'
$chkOpt.Checked = [bool]$Cfg.OptBuild
$gSet.Controls.Add($chkOpt)
$tt.SetToolTip($chkOpt, 'Builds the exe with thin LTO and CPU-specific tuning (target-cpu=native). Slower to build, a little faster to run. Only runs on CPUs like this one. Takes effect on the next Full Setup or Sync + Build.')

function Hw-Text($key) {
    $h = $S.Hw
    $na = 'n/a'
    if ($null -eq $h) { return @{ V = '...'; S = ''; P = 0.0 } }
    switch ($key) {
        'cpu' {
            $v = $na; $pc = 0.0
            if ($null -ne $h.CpuPct) { $v = [string]$h.CpuPct + '%'; $pc = [double]$h.CpuPct }
            $sub = ''
            if ($h.CpuMHz) { $sub = ('{0:N2} GHz' -f ($h.CpuMHz / 1000)) }
            if ($h.CpuTemp) { $sub += '   ' + $h.CpuTemp + ' C' } else { $sub += '   temp n/a' }
            return @{ V = $v; S = $sub.Trim(); P = $pc }
        }
        'ram' {
            if ($null -ne $h.RamUsedGB -and $h.RamTotGB) {
                $rp = 100.0 * $h.RamUsedGB / $h.RamTotGB
                return @{ V = ('{0:N1} / {1:N0} GB' -f $h.RamUsedGB, $h.RamTotGB); S = ('{0:N0}%' -f $rp); P = $rp }
            }
            return @{ V = $na; S = ''; P = 0.0 }
        }
        'gpu' {
            $v = $na; $pc = 0.0
            if ($null -ne $h.GpuPct) { $v = [string]$h.GpuPct + '%'; $pc = [double]$h.GpuPct }
            $nm = [string]$h.GpuName
            $nm = $nm.Replace('NVIDIA GeForce ', '').Replace('NVIDIA ', '')
            $sub = $nm
            if ($h.GpuTemp) { $sub += '   ' + $h.GpuTemp + ' C' }
            return @{ V = $v; S = $sub.Trim(); P = $pc }
        }
        'vram' {
            if ($null -ne $h.GpuMemGB) {
                $t = ('{0:N1}' -f $h.GpuMemGB)
                $pc = 0.0
                if ($h.GpuMemTotGB) { $t += ' / ' + ('{0:N0}' -f $h.GpuMemTotGB); $pc = 100.0 * $h.GpuMemGB / $h.GpuMemTotGB }
                $sub = ''
                if ($h.GpuClk) { $sub = [string]$h.GpuClk + ' MHz' }
                return @{ V = ($t + ' GB'); S = $sub; P = $pc }
            }
            return @{ V = $na; S = ''; P = 0.0 }
        }
    }
    return @{ V = ''; S = ''; P = 0.0 }
}

function Cache-Text($tag) {
    $c = $null
    if ($S.CacheV) { $c = $S.CacheV[$tag] }
    if ($null -eq $c) { return @{ V = '...'; S = '' } }
    $sz = ('{0:N0} MB' -f $c.MB)
    if ($c.MB -ge 1024) { $sz = ('{0:N2} GB' -f ($c.MB / 1024)) }
    return @{ V = ('{0:N0} files    {1}' -f $c.Files, $sz); S = [string]$c.Rate }
}

function Proc-Text {
    $t = [string]$lblProc.Text
    $t = $t -replace '^Processes:\s*', ''
    if ($t -like 'none of*') { return 'none running' }
    return $t
}

function Paint-Tile($g, [single]$x, [single]$y, [single]$w, [single]$h, [string]$k, [string]$v, [string]$sub, [double]$pct, [bool]$bar, [string]$rt = '', [bool]$hfill = $false) {
    $bg = New-Object System.Drawing.SolidBrush($thInput)
    $g.FillRectangle($bg, $x, $y, $w, $h)
    $bg.Dispose()
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(58, 42, 110))
    $g.DrawRectangle($pen, $x, $y, ($w - 1), ($h - 1))
    $pen.Dispose()
    if ($hfill) {
        $fillW = [int](($w - 2) * [math]::Max(0.0, [math]::Min(100.0, $pct)) / 100.0)
        if ($fillW -ge 2) {
            $fr = New-Object System.Drawing.Rectangle(([int]$x + 1), ([int]$y + 1), $fillW, ([int]$h - 2))
            $c1 = [System.Drawing.Color]::FromArgb(110, $thOrange.R, $thOrange.G, $thOrange.B)
            $c2 = [System.Drawing.Color]::FromArgb(110, $thPink.R, $thPink.G, $thPink.B)
            $fg = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Rectangle(([int]$x + 1), ([int]$y + 1), [math]::Max(2, ([int]$w - 2)), ([int]$h - 2))), $c1, $c2, [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
            $g.FillRectangle($fg, $fr)
            $fg.Dispose()
        }
    }
    $sf = New-Object System.Drawing.StringFormat
    $sf.Trimming = 'EllipsisCharacter'
    $sf.FormatFlags = 'NoWrap'
    $bDim = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 140, 175))
    $bTx = New-Object System.Drawing.SolidBrush($thText)
    $y1 = $y + 2
    $g.DrawString($k, $tileK, $bDim, (New-Object System.Drawing.RectangleF(($x + 8), $y1, ($w - 14), $tileK.Height)), $sf)
    $y2 = $y1 + $tileK.Height
    if ($k -eq 'PROCESSES' -and ([string]$v) -like '*x[0-9]*') {
        $sfW = New-Object System.Drawing.StringFormat
        $sfW.Trimming = 'EllipsisCharacter'
        $lines = (([string]$v) -replace '\s*\|\s*', "`n")
        $g.DrawString($lines, $tileS, $bTx, (New-Object System.Drawing.RectangleF(($x + 8), $y2, ($w - 14), ($h - $y2 + $y - 2))), $sfW)
        $sfW.Dispose()
    } else {
        $g.DrawString($v, $tileV, $bTx, (New-Object System.Drawing.RectangleF(($x + 8), $y2, ($w - 14), $tileV.Height)), $sf)
    }
    $y3 = $y2 + $tileV.Height
    if ($rt) {
        $sfR = New-Object System.Drawing.StringFormat
        $sfR.Alignment = 'Far'
        $sfR.Trimming = 'EllipsisCharacter'
        $sfR.FormatFlags = 'NoWrap'
        $bCy = New-Object System.Drawing.SolidBrush($thCyan)
        $g.DrawString($rt, $tileS, $bCy, (New-Object System.Drawing.RectangleF(($x + 8), ($y + 2), ($w - 14), $tileS.Height)), $sfR)
        $bCy.Dispose(); $sfR.Dispose()
    }
    if ($sub) { $g.DrawString($sub, $tileS, $bDim, (New-Object System.Drawing.RectangleF(($x + 8), $y3, ($w - 14), $tileS.Height)), $sf) }
    if ($bar) {
        $tr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(36, 21, 72))
        $g.FillRectangle($tr, ($x + 1), ($y + $h - 5), ($w - 2), 4)
        $tr.Dispose()
        $fw = [int](($w - 2) * [math]::Max(0.0, [math]::Min(100.0, $pct)) / 100.0)
        if ($fw -ge 2) {
            $gr = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Rectangle(([int]$x + 1), ([int]($y + $h - 5)), $fw, 4)), $thOrange, $thPink, [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
            $g.FillRectangle($gr, ($x + 1), ($y + $h - 5), $fw, 4)
            $gr.Dispose()
        }
    }
    $sf.Dispose(); $bDim.Dispose(); $bTx.Dispose()
}

function Paint-Chips($g, $rect) {
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $items = New-Object System.Collections.ArrayList
    $c = Hw-Text 'cpu'; [void]$items.Add('CPU ' + $c.V + '  ' + $c.S)
    $c = Hw-Text 'ram'; [void]$items.Add('RAM ' + $c.V)
    $c = Hw-Text 'gpu'; [void]$items.Add('GPU ' + $c.V + '  ' + $c.S)
    $c = Hw-Text 'vram'; [void]$items.Add('VRAM ' + $c.V)
    $c = Cache-Text 'DXIL'; [void]$items.Add('DXIL ' + $c.V)
    $c = Cache-Text 'D3D12'; [void]$items.Add('D3D12 ' + $c.V)
    [void]$items.Add('Proc: ' + (Proc-Text))
    $x = 2.0
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(58, 42, 110))
    $bTx = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, 180, 215))
    $row = 0
    $chH = [single]($tileS.Height + 6)
    foreach ($it in $items) {
        $txt = [string]$it
        $sz = $g.MeasureString($txt, $tileS)
        $cw = [single]($sz.Width + 12)
        if (($x + $cw) -gt $rect.Width) { $x = 2.0; $row = $row + 1 }
        $y = [single](1 + $row * ($chH + 3))
        if (($y + $chH) -gt $rect.Height) { break }
        $g.DrawRectangle($pen, $x, $y, $cw, $chH)
        $g.DrawString($txt, $tileS, $bTx, ($x + 6), ($y + 3))
        $x = $x + $cw + 6
    }
    $pen.Dispose(); $bTx.Dispose()
}

function Apply-Layout {
    $sc = 1.0
    if ($dpiK) { $sc = [double]$dpiK }
    $U = { param($v) [int][math]::Round($v * $sc) }
    $det = ([string]$Cfg.Layout -ne 'Minimal')
    $x0 = & $U 12
    $W = $gSt.Width - (& $U 24)
    if ($W -lt (& $U 300)) { return }
    $btnLayout.Text = 'Layout: ' + $(if ($det) { 'Detailed' } else { 'Minimal' })
    $btnLayout.SetBounds(($x0 + $W - (& $U 158)), (& $U 14), (& $U 128), (& $U 24))
    $lblRepo.SetBounds($x0, (& $U 18), ($W - (& $U 170)), (& $U 22))
    $lblStep.SetBounds($x0, (& $U 42), (& $U 420), (& $U 26))
    $lblStatus.SetBounds(($x0 + (& $U 430)), (& $U 44), ([math]::Max((& $U 100), ($W - (& $U 430)))), (& $U 22))
    $lblStatus.TextAlign = 'MiddleRight'
    $folded = $false
    if ($S.Fold -and $S.Fold['St']) { $folded = $true }
    if (-not $folded) {
        foreach ($c in @($capOv, $capSt, $capFi, $lblEtaOverall, $lblEtaStep, $lblEtaFile, $pnlCache, $spI2)) { $c.Visible = $det }
        $spI1.Visible = $true
    }
    $fh = & $U 160
    if ($det) {
        $bx = $x0 + (& $U 68)
        $ex = $x0 + $W - (& $U 128)
        $bw = $ex - (& $U 6) - $bx
        $capOv.SetBounds($x0, (& $U 74), (& $U 66), (& $U 20))
        $capSt.SetBounds($x0, (& $U 100), (& $U 66), (& $U 20))
        $capFi.SetBounds($x0, (& $U 126), (& $U 66), (& $U 20))
        $barOverall.SetBounds($bx, (& $U 72), $bw, (& $U 22))
        $barStep.SetBounds($bx, (& $U 98), $bw, (& $U 22))
        $barFile.SetBounds($bx, (& $U 124), $bw, (& $U 22))
        $lblEtaOverall.SetBounds($ex, (& $U 72), (& $U 128), (& $U 22))
        $lblEtaStep.SetBounds($ex, (& $U 98), (& $U 128), (& $U 22))
        $lblEtaFile.SetBounds($ex, (& $U 124), (& $U 128), (& $U 22))
        $thv = 52; if ([double]$Cfg.TileH -gt 0) { $thv = [double]$Cfg.TileH }
        $chv = 48; if ([double]$Cfg.CacheH -gt 0) { $chv = [double]$Cfg.CacheH }
        $ty = & $U 152
        $pnlTiles.SetBounds($x0, $ty, $W, (& $U $thv))
        $spI1.SetBounds($x0, ($ty + (& $U $thv)), $W, (& $U 5))
        $cy2 = $ty + (& $U $thv) + (& $U 5)
        $pnlCache.SetBounds($x0, $cy2, $W, (& $U $chv))
        $spI2.SetBounds($x0, ($cy2 + (& $U $chv)), $W, (& $U 5))
        $ft = $cy2 + (& $U $chv) + (& $U 5)
    } else {
        $half = [int](($W - (& $U 10)) / 2)
        $barOverall.SetBounds($x0, (& $U 72), $half, (& $U 22))
        $barStep.SetBounds(($x0 + $half + (& $U 10)), (& $U 72), $half, (& $U 22))
        $barFile.SetBounds($x0, (& $U 98), $W, (& $U 22))
        $thv = 54; if ([double]$Cfg.TileH -gt 0) { $thv = [double]$Cfg.TileH }
        $ty = & $U 126
        $pnlTiles.SetBounds($x0, $ty, $W, (& $U $thv))
        $spI1.SetBounds($x0, ($ty + (& $U $thv)), $W, (& $U 5))
        $ft = $ty + (& $U $thv) + (& $U 5)
    }
    $fh = [math]::Max((& $U 110), ($gSt.Height - $ft - (& $U 12)))
    $pnlFeed.SetBounds($x0, $ft, $W, $fh)
    foreach ($c in @($barOverall, $barStep, $barFile, $pnlTiles, $pnlCache, $pnlFeed)) { $c.Invalidate() }
}

function Get-DefSt {
    if ([string]$Cfg.Layout -eq 'Minimal') { return 356 }
    return 432
}

# ---- Live status group ----
$gSt = New-Object System.Windows.Forms.GroupBox
$gSt.Text = 'Live status'
$gSt.SetBounds(10, 380, 930, 318)
$gSt.Anchor = 'Top, Left'
$body.Controls.Add($gSt)

$lblRepo = New-Label 'Repo: ...' 12 18 770 22
$lblRepo.Anchor = 'Top, Left, Right'
$gSt.Controls.Add($lblRepo)
$lblStep = New-Label 'Idle - ready' 12 44 492 26
$lblStep.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$gSt.Controls.Add($lblStep)
$lblStatus = New-Label 'Status: ...' 440 44 478 22
$lblStatus.Anchor = 'Top, Left, Right'
$gSt.Controls.Add($lblStatus)
$lblHw = New-Label 'CPU / GPU: reading...' 12 102 906 24
$lblHw.Anchor = 'Top, Left, Right'
$gSt.Controls.Add($lblHw)
$lblProc = New-Label 'Processes: ...' 12 184 440 60
$gSt.Controls.Add($lblProc)
$lblDx = New-Label 'DXIL cache: ...' 12 130 440 24
$gSt.Controls.Add($lblDx)
$lblD3 = New-Label 'D3D12 cache: ...' 12 156 440 24
$gSt.Controls.Add($lblD3)
foreach ($c in @($lblHw, $lblProc, $lblDx, $lblD3)) { $c.Visible = $false }

$tileK = New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Bold)
$tileV = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$tileS = New-Object System.Drawing.Font('Segoe UI', 8.5)

$btnLayout = New-Btn 'Layout' 790 14 128 24
$btnLayout.Anchor = 'Top, Right'
$gSt.Controls.Add($btnLayout)
$tt.SetToolTip($btnLayout, 'Switch between the Detailed layout (tiles for every number) and the Minimal one (compact chips).')

$spI1 = New-Object System.Windows.Forms.Panel
$spI2 = New-Object System.Windows.Forms.Panel
foreach ($c in @($spI1, $spI2)) {
    $c.BackColor = $thBg
    $c.Add_MouseEnter({ param($sender, $e) $sender.BackColor = $thPink })
    $c.Add_MouseLeave({ param($sender, $e) $sender.BackColor = $thBg })
    $c.Cursor = [System.Windows.Forms.Cursors]::SizeNS
    $c.Anchor = 'Top, Left'
    $gSt.Controls.Add($c)
    $tt.SetToolTip($c, 'Drag to resize')
}
$spI1.Tag = 'TileH'
$spI2.Tag = 'CacheH'
$inDown = { param($sender, $e)
    $key = [string]$sender.Tag
    $cur = [double]$Cfg[$key]
    if ($cur -le 0) { if ($key -eq 'TileH') { $cur = $(if ([string]$Cfg.Layout -eq 'Minimal') { 54 } else { 52 }) } else { $cur = 48 } }
    $S.DragI = @{ Sp = $sender; Y0 = [System.Windows.Forms.Cursor]::Position.Y; V0 = $cur }
    $sender.Capture = $true
}
$inMove = { param($sender, $e)
    $d = $S.DragI
    if ($null -eq $d -or $d.Sp -ne $sender) { return }
    $sc = 1.0
    if ($dpiK) { $sc = [double]$dpiK }
    $dy = ([System.Windows.Forms.Cursor]::Position.Y - $d.Y0) / $sc
    $Cfg[[string]$sender.Tag] = [math]::Max(36.0, ($d.V0 + $dy))
    Apply-Layout
}
$inUp = { param($sender, $e) if ($S.DragI) { $S.DragI = $null; $sender.Capture = $false; Save-Settings } }
foreach ($c in @($spI1, $spI2)) { $c.Add_MouseDown($inDown); $c.Add_MouseMove($inMove); $c.Add_MouseUp($inUp) }

$capOv = New-Label 'OVERALL' 12 74 66 20
$capSt = New-Label 'STEP' 12 100 66 20
$capFi = New-Label 'FILE' 12 126 66 20
foreach ($c in @($capOv, $capSt, $capFi)) { $c.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold); $c.ForeColor = $colGray; $gSt.Controls.Add($c) }

$pnlTiles = New-Object System.Windows.Forms.Panel
$pnlTiles.Anchor = 'Top, Left, Right'
$pnlTiles.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $rc = $sender.ClientRectangle
    if ([string]$Cfg.Layout -eq 'Minimal') { Paint-Chips $g $rc; return }
    $n = 5
    $gap = 6.0
    $tw = ($rc.Width - $gap * ($n - 1)) / $n
    $keys = @('cpu', 'ram', 'gpu', 'vram')
    $caps = @('CPU', 'RAM', 'GPU', 'VRAM')
    for ($i = 0; $i -lt 4; $i++) {
        $t = Hw-Text $keys[$i]
        Paint-Tile $g ([single]($i * ($tw + $gap))) 0 ([single]$tw) ([single]$rc.Height) $caps[$i] $t.V $t.S $t.P $false '' $true
    }
    Paint-Tile $g ([single](4 * ($tw + $gap))) 0 ([single]$tw) ([single]$rc.Height) 'PROCESSES' (Proc-Text) '' 0.0 $false
})
$gSt.Controls.Add($pnlTiles)
Set-DoubleBuffer $pnlTiles

$pnlCache = New-Object System.Windows.Forms.Panel
$pnlCache.Anchor = 'Top, Left, Right'
$pnlCache.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $rc = $sender.ClientRectangle
    $gap = 6.0
    $tw = ($rc.Width - $gap) / 2
    $act = ($S.Running -and ([string]$S.StepName -like 'Pre-compile*'))
    $pcP = 0.0; $pcD = 0.0
    $rtP = 'idle'; $rtD = 'idle'
    if ($act) {
        $pcP = [double]$S.StepPct
        $pcD = $pcP
        if ($null -ne $S.FracFiles) { $pcD = [double]$S.FracFiles * 100.0 }
        $etaT = ([string]$lblEtaStep.Text) -replace '^ETA\s*', ''
        $rtP = ('~{0:N0}%   ETA {1}' -f $pcP, $etaT)
        $rtD = ('~{0:N0}%   ETA {1}' -f $pcD, $etaT)
    }
    $a = Cache-Text 'DXIL'
    Paint-Tile $g 0 0 ([single]$tw) ([single]$rc.Height) 'DXIL CACHE' $a.V $a.S $pcD $false $rtD $true
    $b = Cache-Text 'D3D12'
    Paint-Tile $g ([single]($tw + $gap)) 0 ([single]$tw) ([single]$rc.Height) 'D3D12 CACHE' $b.V $b.S $pcP $false $rtP $true
})
$gSt.Controls.Add($pnlCache)
Set-DoubleBuffer $pnlCache

$pnlFeed = New-Object System.Windows.Forms.Panel
$pnlFeed.SetBounds(460, 130, 456, 182)
$pnlFeed.Anchor = 'Top, Left, Right'
$feedF  = New-Object System.Drawing.Font('Segoe UI', 10)
$feedFB = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$feedFH = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
$feedFS = New-Object System.Drawing.Font('Segoe UI', 8.5)
$pnlFeed.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $g.SmoothingMode = 'AntiAlias'
    $r = $sender.ClientRectangle
    $bg = New-Object System.Drawing.SolidBrush($thInput)
    $g.FillRectangle($bg, $r)
    $bg.Dispose()
    $pen = New-Object System.Drawing.Pen($thPurple)
    $g.DrawRectangle($pen, 0, 0, ($r.Width - 1), ($r.Height - 1))
    $pen.Dispose()
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Trimming = 'EllipsisCharacter'
    $fmt.FormatFlags = 'NoWrap'
    $fmtR = New-Object System.Drawing.StringFormat
    $fmtR.Alignment = 'Far'
    $fmtR.FormatFlags = 'NoWrap'
    $bPink = New-Object System.Drawing.SolidBrush($thPink)
    $bGray = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 140, 175))
    $bText = New-Object System.Drawing.SolidBrush($thText)
    $bGreen = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(80, 235, 140))
    $bCyan = New-Object System.Drawing.SolidBrush($thCyan)
    $bViolet = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, 130, 255))
    $hh = $feedFH.Height + 4
    $w = [single]$r.Width
    $g.DrawString('LATEST FILES WRITTEN', $feedFH, $bPink, (New-Object System.Drawing.RectangleF(8, 3, ($w - 90), $hh)), $fmt)
    $g.DrawString(('writing ' + $(if ([double]$S.TotSpd -ge 1.0) { ('{0:N1} MB/s' -f [double]$S.TotSpd) } else { ('{0:N0} KB/s' -f ([double]$S.TotSpd * 1024)) })), $feedFH, $bGray, (New-Object System.Drawing.RectangleF(0, 3, ($w - 8), $hh)), $fmtR)
    $sep = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 50, 110))
    $g.DrawLine($sep, 6, $hh + 3, ($r.Width - 7), $hh + 3)
    $sep.Dispose()
    $rows = $S.Feed
    $rh = $feedF.Height + 4
    $y0 = $hh + 6
    $foot = 0
    if ($null -ne $rows -and $rows.Count -gt 0) { $foot = $feedFS.Height * 2 + 10 }
    $max = [int][math]::Floor(($r.Height - $y0 - 2 - $foot) / $rh)
    if ($null -eq $rows -or $rows.Count -eq 0) {
        $g.DrawString('Nothing written in the last 15 minutes', $feedF, $bGray, (New-Object System.Drawing.RectangleF(8, $y0, ($w - 16), $rh)), $fmt)
    } else {
        $i = 0
        foreach ($row in $rows) {
            if ($i -ge $max) { break }
            $y = $y0 + $i * $rh
            $dot = $bViolet
            if ($row.Kind -ne 'Shader') { $dot = $bCyan }
            $g.FillEllipse($dot, 8, ($y + $rh / 2 - 3), 6, 6)
            $g.DrawString($row.Kind, $feedF, $dot, (New-Object System.Drawing.RectangleF(19, $y, 80, $rh)), $fmt)
            $g.DrawString($row.Size, $feedFB, $bText, (New-Object System.Drawing.RectangleF(98, $y, 84, $rh)), $fmtR)
            $g.DrawString($row.Name, $feedF, $bGray, (New-Object System.Drawing.RectangleF(192, $y, ($w - 192 - 78), $rh)), $fmt)
            $ab = $bGray
            if ($row.Fresh) { $ab = $bGreen }
            $g.DrawString($row.Age, $feedF, $ab, (New-Object System.Drawing.RectangleF(0, $y, ($w - 8), $rh)), $fmtR)
            $i = $i + 1
        }
    }
    if ($null -ne $rows -and $rows.Count -gt 0) {
        $fh2 = $feedFS.Height * 2 + 2
        $fy = $r.Height - $fh2 - 5
        $sep2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 50, 110))
        $g.DrawLine($sep2, 6, $fy - 3, ($r.Width - 7), $fy - 3)
        $sep2.Dispose()
        $fmtP = New-Object System.Drawing.StringFormat
        $fmtP.Trimming = 'EllipsisCharacter'
        $g.DrawString('NOW', $feedFH, $bPink, (New-Object System.Drawing.RectangleF(8, $fy, 60, $rh)), $fmt)
        $what = 'shader'
        if ($rows[0].Kind -ne 'Shader') { $what = 'pipeline cache' }
        $g.DrawString(($what + ': ' + [string]$rows[0].Leaf), $feedFS, $bText, (New-Object System.Drawing.RectangleF(66, $fy, ($w - 74), $fh2)), $fmtP)
        $fmtP.Dispose()
    }
    foreach ($o in @($fmt, $fmtR, $bPink, $bGray, $bText, $bGreen, $bCyan, $bViolet)) { $o.Dispose() }
})
$pnlFeed.Add_MouseMove({
    param($sender, $e)
    $rh2 = $feedF.Height + 4
    $y02 = $feedFH.Height + 10
    $idx = [int][math]::Floor(($e.Y - $y02) / $rh2)
    $txt = ''
    if ($S.Feed -and $idx -ge 0 -and $idx -lt $S.Feed.Count) { $txt = [string]$S.Feed[$idx].Full }
    if ($txt -ne $S.FeedTip) { $S.FeedTip = $txt; $tt.SetToolTip($sender, $txt) }
})
$gSt.Controls.Add($pnlFeed)
Set-DoubleBuffer $pnlFeed

$barOverall = New-Object System.Windows.Forms.Panel
$barOverall.SetBounds(512, 44, 296, 24)
$barOverall.Anchor = 'Top, Left, Right'
$barOverall.Add_Paint({ param($sender, $e)
    $tx = [string]$S.OverallText
    if ([string]$Cfg.Layout -eq 'Minimal') { $tx += '   |   ' + $lblEtaOverall.Text }
    Paint-Bar $e.Graphics $sender.ClientRectangle ([double]$S.OverallPct) $false $tx })
$gSt.Controls.Add($barOverall)
Set-DoubleBuffer $barOverall

$barStep = New-Object System.Windows.Forms.Panel
$barStep.SetBounds(512, 74, 296, 24)
$barStep.Anchor = 'Top, Left, Right'
$barStep.Add_Paint({ param($sender, $e)
    $tx = [string]$S.StepText
    if ([string]$Cfg.Layout -eq 'Minimal') { $tx += '   |   ' + $lblEtaStep.Text }
    Paint-Bar $e.Graphics $sender.ClientRectangle ([double]$S.StepPct) ([bool]$S.StepIndet) $tx })
$gSt.Controls.Add($barStep)
Set-DoubleBuffer $barStep

$barFile = New-Object System.Windows.Forms.Panel
$barFile.Anchor = 'Top, Left, Right'
$barFile.Add_Paint({ param($sender, $e)
    $fbd = $S.FileBar
    $tx = 'idle'; $pc = 0.0; $ind = $false; $act = $false
    if ($fbd) { $tx = [string]$fbd.Text; $pc = [double]$fbd.Pct; $ind = [bool]$fbd.Indet; $act = [bool]$fbd.Active }
    if ([string]$Cfg.Layout -eq 'Minimal') { $tx = 'File:  ' + $tx }
    Paint-Bar $e.Graphics $sender.ClientRectangle $pc $ind $tx
    if ($act -and -not $ind) {
        $r2 = $sender.ClientRectangle
        $bw2 = [int](($r2.Width - 2) * 0.12)
        $sx = [int](($S.Ticks * 22) % (($r2.Width - 2) + $bw2)) - $bw2
        $x0 = [math]::Max(1, $sx)
        $x1 = [math]::Min(($r2.Width - 3), $sx + $bw2)
        if ($x1 -gt $x0) {
            $sh = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(55, 255, 255, 255))
            $e.Graphics.FillRectangle($sh, $x0, 1, ($x1 - $x0), ($r2.Height - 3))
            $sh.Dispose()
        }
    }
})
$gSt.Controls.Add($barFile)
Set-DoubleBuffer $barFile

$lblEtaOverall = New-Label 'ETA --:--:--' 814 44 102 24
$lblEtaOverall.TextAlign = 'MiddleRight'
$lblEtaOverall.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblEtaOverall.ForeColor = $colGray
$gSt.Controls.Add($lblEtaOverall)
$lblEtaStep = New-Label 'ETA --:--:--' 814 74 102 24
$lblEtaStep.TextAlign = 'MiddleRight'
$lblEtaStep.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblEtaStep.ForeColor = $colGray
$gSt.Controls.Add($lblEtaStep)
$lblEtaFile = New-Label 'idle' 814 104 102 24
$lblEtaFile.TextAlign = 'MiddleRight'
$lblEtaFile.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblEtaFile.ForeColor = $colGray
$gSt.Controls.Add($lblEtaFile)
$btnLayout.Visible = $false
$btnLayout.Add_Click({
    $prevH = $gSt.Height
    if ([string]$Cfg.Layout -eq 'Minimal') { $Cfg.Layout = 'Detailed' } else { $Cfg.Layout = 'Minimal' }
    $Cfg.SecH = ''
    Save-Settings
    Arrange-Sections
    $dl = $gSt.Height - $prevH
    if ($dl -ne 0 -and [string]$Cfg.Resize -ne 'Panes') {
        try {
            $wa2 = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
            $nh = [math]::Min($wa2.Height, ($form.Height + $dl))
            $form.Height = [math]::Max($form.MinimumSize.Height, $nh)
        } catch {}
    }
    Arrange-Sections
})
$tt.SetToolTip($lblEtaOverall, 'Estimated time left for everything in this run.')
$tt.SetToolTip($lblEtaStep, 'Estimated time left for the step that is running now.')

# ---- Log ----
$gLog = New-Object System.Windows.Forms.GroupBox
$gLog.Text = 'Log'
$gLog.SetBounds(10, 702, 930, 144)
$body.Controls.Add($gLog)

$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.SetBounds(8, 20, 914, 92)
$rtb.Anchor = 'Top, Bottom, Left, Right'
$rtb.ReadOnly = $true
$rtb.BackColor = [System.Drawing.Color]::White
$rtb.ForeColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$rtb.Font = New-Object System.Drawing.Font('Consolas', 10.5)
$rtb.DetectUrls = $false
$rtb.HideSelection = $false
$gLog.Controls.Add($rtb)

$lblLive = New-Label '' 8 116 914 22
$lblLive.Anchor = 'Bottom, Left, Right'
$lblLive.ForeColor = $colGray
$lblLive.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$gLog.Controls.Add($lblLive)

function Layout-Settings {
    if ($S.Fold -and $S.Fold['Set']) { return }
    $sc = 1.0
    if ($dpiK) { $sc = [double]$dpiK }
    if ($null -eq $S.SetOrig) {
        $o = @{}
        foreach ($c in $gSet.Controls) {
            if ([string]$c.Tag -eq 'keep') { continue }
            $o[$c] = @{ X = [double]$c.Left / $sc; Y = [double]$c.Top / $sc; W = [double]$c.Width / $sc; H = [double]$c.Height / $sc; A = [string]$c.Anchor }
        }
        $S.SetOrig = $o
    }
    $Gw = [double]$gSet.Width / $sc
    $Gh = [double]$gSet.Height / $sc
    if ($Gw -lt 300) { return }
    $pitch = ($Gh - 30.0) / 5.0
    if ($pitch -lt 22.0) { $pitch = 22.0 }
    if ($pitch -gt 40.0) { $pitch = 40.0 }
    $half = ($Gw - 24.0) / 2.0
    $rows = @{}
    foreach ($c in $S.SetOrig.Keys) {
        $r = [int][math]::Floor(($S.SetOrig[$c].Y - 12.0) / 28.0)
        if (-not $rows.ContainsKey($r)) { $rows[$r] = New-Object System.Collections.ArrayList }
        [void]$rows[$r].Add($c)
    }
    foreach ($r in $rows.Keys) {
        $col = 0; $nr = $r
        if ($r -le 5) { $nr = [math]::Floor($r / 2); $col = $r % 2 } else { $nr = $r - 3 }
        $base = 20.0 + $nr * $pitch + ($pitch - 28.0) / 2.0
        if ($r -le 5) {
            $x0 = 8.0 + $col * ($half + 8.0)
            $x1 = $x0 + $half
            $lblW = 84.0
            $btn = $null
            foreach ($c in $rows[$r]) { if ($c -is [System.Windows.Forms.Button]) { $btn = $c } }
            foreach ($c in $rows[$r]) {
                $o = $S.SetOrig[$c]
                $dy = $o.Y - (18.0 + $r * 28.0)
                $nx = $x0; $nw = $o.W
                if ($c -is [System.Windows.Forms.Label]) { $nx = $x0; $nw = $lblW }
                elseif ($c -is [System.Windows.Forms.Button]) { $nw = 78.0; $nx = $x1 - $nw }
                else {
                    $nx = $x0 + $lblW + 2.0
                    $right = $x1
                    if ($null -ne $btn) { $right = $x1 - 78.0 - 4.0 }
                    $nw = $right - $nx
                }
                $c.Anchor = 'Top, Left'
                $c.SetBounds([int]($nx * $sc), [int](($base + $dy) * $sc), [int]($nw * $sc), [int]($o.H * $sc))
            }
        } else {
            foreach ($c in $rows[$r]) {
                $o = $S.SetOrig[$c]
                $dy = $o.Y - (18.0 + $r * 28.0)
                $nx = $o.X; $nw = $o.W
                $an = $o.A
                $hasR = ($an -like '*Right*'); $hasL = ($an -like '*Left*')
                if ($hasR -and $hasL) { $nw = ($Gw - 16.0) - $nx }
                elseif ($hasR) { $nx = ($Gw - 16.0) - $nw }
                $c.Anchor = 'Top, Left'
                $c.SetBounds([int]($nx * $sc), [int](($base + $dy) * $sc), [int]($nw * $sc), [int]($o.H * $sc))
            }
        }
    }
}

function Layout-Actions {
    if ($S.Fold -and $S.Fold['Act']) { return }
    $sc = 1.0
    if ($dpiK) { $sc = [double]$dpiK }
    $x0 = [int][math]::Round(12 * $sc)
    $gapx = [int][math]::Round(8 * $sc)
    $W = $gAct.Width - 2 * $x0
    if ($W -lt 200) { return }
    $y1 = [int][math]::Round(22 * $sc)
    $availA = ([double]$gAct.Height / $sc) - 30.0 - 8.0
    $h1d = [math]::Max(30.0, [math]::Min(80.0, $availA * 0.56))
    $h2d = [math]::Max(24.0, [math]::Min(60.0, $availA * 0.44))
    $h1 = [int][math]::Round($h1d * $sc)
    $y2 = $y1 + $h1 + $gapx
    $h2 = [int][math]::Round($h2d * $sc)
    $row1 = @($btnFull, $btnSync, $btnShaders, $btnLaunch, $btnStop)
    $bz = Get-Variable -Name btnZip -ValueOnly -ErrorAction SilentlyContinue
    $row2 = @($btnCheck, $btnCache, $btnMigrate)
    if ($bz) { $row2 += $bz }
    $row2 += $btnClear
    if ($btnFull.Text -like 'Full Setup  (*') { $btnFull.Text = 'Full Setup' }
    if ($btnShaders.Text -eq 'Compile Shaders Only') { $btnShaders.Text = 'Compile Shaders' }
    $n = $row1.Count
    $bw = [int][math]::Floor(($W - ($n - 1) * $gapx) / $n)
    for ($i = 0; $i -lt $n; $i++) {
        $row1[$i].Anchor = 'Top, Left'
        $row1[$i].SetBounds(($x0 + $i * ($bw + $gapx)), $y1, $bw, $h1)
    }
    $n2 = $row2.Count
    $bw2 = [int][math]::Floor(($W - ($n2 - 1) * $gapx) / $n2)
    for ($i = 0; $i -lt $n2; $i++) {
        $row2[$i].Anchor = 'Top, Left'
        $row2[$i].SetBounds(($x0 + $i * ($bw2 + $gapx)), $y2, $bw2, $h2)
    }
}

# ---- Resizable boxes: modes Drag / Fold / Panes ----
$S.Fold = @{ Set = $false; Act = $false; St = $false; Log = $false }
$S.Drag = $null
foreach ($c in @($gSet, $gAct, $gSt, $gLog)) { $c.Anchor = 'Top, Left' }
$SecMap = @{
    Set = @{ Ctl = $gSet; Title = 'Settings'; Hidden = $null }
    Act = @{ Ctl = $gAct; Title = 'Actions'; Hidden = $null }
    St  = @{ Ctl = $gSt;  Title = 'Live status'; Hidden = $null }
    Log = @{ Ctl = $gLog; Title = 'Log'; Hidden = $null }
}
$DefH = @{ Set = 170; Act = 118 }

function Get-SecH {
    $h = @{ Set = [double]$DefH.Set; Act = [double]$DefH.Act; St = [double](Get-DefSt) }
    $t = [string]$Cfg.SecH
    if ($t) {
        $p = $t.Split(',')
        if ($p.Count -ge 4) {
            try { $h.Set = [double]$p[0]; $h.Act = [double]$p[1]; $h.St = [double]$p[2] } catch {}
        }
    }
    foreach ($k in @('Set', 'Act', 'St')) { if ($h[$k] -lt 44) { $h[$k] = 44 } }
    return $h
}

function Put-SecH($h) {
    $Cfg.SecH = ('{0:F0},{1:F0},{2:F0},v2' -f $h.Set, $h.Act, $h.St)
}

function Set-Fold($key, [bool]$on) {
    $sec = $SecMap[$key]
    $ctl = $sec.Ctl
    if ($on -and -not $S.Fold[$key]) {
        $keep = New-Object System.Collections.ArrayList
        foreach ($c in $ctl.Controls) {
            if ($c.Tag -ne 'keep' -and $c.Visible) { [void]$keep.Add($c); $c.Visible = $false }
        }
        $sec.Hidden = $keep
        $S.Fold[$key] = $true
    } elseif ((-not $on) -and $S.Fold[$key]) {
        foreach ($c in $sec.Hidden) { $c.Visible = $true }
        $sec.Hidden = $null
        $S.Fold[$key] = $false
    }
    $FoldBtns[$key].Text = $(if ($S.Fold[$key]) { '>' } else { 'v' })
    $ctl.Text = $(if ($S.Fold[$key]) { $sec.Title + '  (folded)' } else { $sec.Title })
}

function Arrange-Sections {
    if ($S.InArrange) { return }
    $S.InArrange = $true
    try {
        $sc = 1.0
        if ($dpiK) { $sc = [double]$dpiK }
        $mode = [string]$Cfg.Resize
        if ($mode -ne 'Fold' -and $mode -ne 'Panes') { $mode = 'Drag' }
        $m = [int][math]::Round(10 * $sc)
        $sp = [int][math]::Round(5 * $sc)
        $gp = [int][math]::Round(4 * $sc)
        $hc = [int][math]::Round(26 * $sc)
        $minH = [int][math]::Round(44 * $sc)
        $h = Get-SecH
        $BW = $body.ClientSize.Width
        $BH = $body.ClientSize.Height
        if (-not $S.ArrInit) {
            $S.ArrInit = $true
            $need = [int](62 * $sc) + $m + [int](($h.Set + $h.Act + $h.St) * $sc) + 3 * $sp + [int](130 * $sc) + $m
            try {
                $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
                $gdi0 = $form.CreateGraphics()
                $kd = [double]$gdi0.DpiX / 96.0
                $gdi0.Dispose()
                if ($kd -lt 1.0) { $kd = 1.0 }
                $lim = [int](($wa.Height - 70) / $kd)
                $form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, [math]::Min($need, $lim))
                $BW = $body.ClientSize.Width
                $BH = $body.ClientSize.Height
            } catch {}
        }
        if ($mode -ne 'Panes') {
            $gD = $(if ($mode -eq 'Drag') { 5.0 } else { 4.0 })
            $eff = @{ Set = $h.Set; Act = $h.Act; St = $h.St }
            foreach ($k in @('Set', 'Act', 'St')) { if ($S.Fold[$k]) { $eff[$k] = 26.0 } }
            $availD = ($BH / $sc) - 20.0 - 3.0 * $gD
            $logMin = $(if ($S.Fold['Log']) { 26.0 } else { 130.0 })
            $over = $eff.Set + $eff.Act + $eff.St + $logMin - $availD
            if ($over -gt 0 -and -not $S.Fold['St']) { $cut = [math]::Min($over, [math]::Max(0.0, $eff.St - 200.0)); $eff.St -= $cut; $over -= $cut }
            if ($over -gt 0 -and -not $S.Fold['Set']) { $cut = [math]::Min($over, [math]::Max(0.0, $eff.Set - 140.0)); $eff.Set -= $cut; $over -= $cut }
            if ($over -gt 0 -and -not $S.Fold['Act']) { $cut = [math]::Min($over, [math]::Max(0.0, $eff.Act - 70.0)); $eff.Act -= $cut; $over -= $cut }
            $h = $eff
        }
        $spl = @($spH1, $spH2, $spH3)
        foreach ($c in @($spH1, $spH2, $spH3, $spV1)) { $c.Visible = $false }
        foreach ($k in @('Set', 'Act', 'St')) { $GripBtns[$k].Visible = ($mode -eq 'Fold' -and -not $S.Fold[$k]) }
        foreach ($k in $FoldBtns.Keys) { $FoldBtns[$k].Visible = ($mode -eq 'Fold') }
        if ($mode -eq 'Panes') {
            $leftW = [int]([double]$Cfg.ColW * $sc)
            if ($leftW -le 0) { $leftW = [int](940 * $sc) }
            $leftW = [math]::Max([int](380 * $sc), [math]::Min($leftW, ($BW - $sp - 2 * $m - [int](330 * $sc))))
            $rightW = $BW - 2 * $m - $sp - $leftW
            $y = $m
            $hs = $(if ($S.Fold['Set']) { $hc } else { [int]($h.Set * $sc) })
            $SecMap.Set.Ctl.SetBounds($m, $y, $leftW, $hs); $y += $hs
            $spH1.SetBounds($m, $y, $leftW, $sp); $spH1.Tag = @{ Up = 'Set'; Down = 'Act'; Flex = $false }; $spH1.Visible = $true; $y += $sp
            $ha = $(if ($S.Fold['Act']) { $hc } else { [int]($h.Act * $sc) })
            $SecMap.Act.Ctl.SetBounds($m, $y, $leftW, $ha); $y += $ha
            $spH2.SetBounds($m, $y, $leftW, $sp); $spH2.Tag = @{ Up = 'Act'; Down = 'Log'; Flex = $true }; $spH2.Visible = $true; $y += $sp
            $hl = $(if ($S.Fold['Log']) { $hc } else { [math]::Max($minH, ($BH - $y - $m)) })
            $SecMap.Log.Ctl.SetBounds($m, $y, $leftW, $hl)
            $spV1.SetBounds(($m + $leftW), $m, $sp, ($BH - 2 * $m)); $spV1.Visible = $true
            $SecMap.St.Ctl.SetBounds(($m + $leftW + $sp), $m, $rightW, ($BH - 2 * $m))
        } else {
            $gap = $(if ($mode -eq 'Drag') { $sp } else { $gp })
            $W2 = $BW - 2 * $m
            $y = $m
            $i = 0
            foreach ($k in @('Set', 'Act', 'St')) {
                $hh = $(if ($S.Fold[$k]) { $hc } else { [int]($h[$k] * $sc) })
                $SecMap[$k].Ctl.SetBounds($m, $y, $W2, $hh)
                $y += $hh
                if ($mode -eq 'Drag') {
                    $nx = @('Act', 'St', 'Log')[$i]
                    $spl[$i].SetBounds($m, $y, $W2, $sp)
                    $spl[$i].Tag = @{ Up = $k; Down = $nx; Flex = ($nx -eq 'Log') }
                    $spl[$i].Visible = $true
                }
                $y += $gap
                $i++
            }
            $hl = $(if ($S.Fold['Log']) { $hc } else { [math]::Max($minH, ($BH - $y - $m)) })
            $SecMap.Log.Ctl.SetBounds($m, $y, $W2, $hl)
        }
        foreach ($k in $FoldBtns.Keys) {
            $g2 = $SecMap[$k].Ctl
            $FoldBtns[$k].SetBounds(($g2.Width - [int](28 * $sc)), 0, [int](24 * $sc), [int](18 * $sc))
            $FoldBtns[$k].BringToFront()
        }
        foreach ($k in @('Set', 'Act', 'St')) {
            $g2 = $SecMap[$k].Ctl
            $GripBtns[$k].SetBounds(($g2.Width - [int](16 * $sc)), ($g2.Height - [int](16 * $sc)), [int](14 * $sc), [int](14 * $sc))
            $GripBtns[$k].BringToFront()
        }
        $lw = $SecMap.Log.Ctl.Width
        $lh = $SecMap.Log.Ctl.Height
        $rtb.SetBounds([int](8 * $sc), [int](20 * $sc), ($lw - [int](16 * $sc)), [math]::Max(10, ($lh - [int](20 * $sc) - [int](28 * $sc))))
        $lblLive.SetBounds([int](8 * $sc), ($lh - [int](26 * $sc)), ($lw - [int](16 * $sc)), [int](22 * $sc))
        Layout-Settings
        Layout-Actions
        if (-not $S.Fold['St']) { Apply-Layout }
        foreach ($c in @($btnRzA, $btnRzB, $btnRzC)) {
            if ([string]$c.Tag -eq $mode) { $c.BackColor = $thPink } else { $c.BackColor = $thBtn }
        }
    } finally {
        $S.InArrange = $false
    }
}

function Set-ResizeMode($mode) {
    foreach ($k in @('Set', 'Act', 'St', 'Log')) { if ($S.Fold[$k]) { Set-Fold $k $false } }
    $Cfg.Resize = $mode
    Save-Settings
    if ($mode -eq 'Panes') {
        try {
            $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
            $want = [int]((940 + 20 + 7 + 900) * $(if ($dpiK) { [double]$dpiK } else { 1.0 }))
            $nw = [math]::Min($wa.Width, $want)
            if ($form.Width -lt $nw) { $form.Width = $nw }
            $form.Left = [math]::Max($wa.Left, [int]($wa.Left + ($wa.Width - $form.Width) / 2))
        } catch {}
    }
    Arrange-Sections
}

$spH1 = New-Object System.Windows.Forms.Panel
$spH2 = New-Object System.Windows.Forms.Panel
$spH3 = New-Object System.Windows.Forms.Panel
$spV1 = New-Object System.Windows.Forms.Panel
foreach ($c in @($spH1, $spH2, $spH3)) { $c.Cursor = [System.Windows.Forms.Cursors]::SizeNS }
$spV1.Cursor = [System.Windows.Forms.Cursors]::SizeWE
$spV1.Tag = @{ Kind = 'V' }
foreach ($c in @($spH1, $spH2, $spH3, $spV1)) {
    $c.BackColor = $thBg
    $c.Visible = $false
    $body.Controls.Add($c)
    $tt.SetToolTip($c, 'Drag to resize')
    $c.Add_MouseEnter({ param($sender, $e) $sender.BackColor = $thPink })
    $c.Add_MouseLeave({ param($sender, $e) if (-not $S.Drag) { $sender.BackColor = $thBg } })
}

$dragDown = {
    param($sender, $e)
    $S.Drag = @{ Sp = $sender; Pos = [System.Windows.Forms.Cursor]::Position; H0 = (Get-SecH); ColW0 = [double]$Cfg.ColW }
    $sender.Capture = $true
}
$dragMove = {
    param($sender, $e)
    $d = $S.Drag
    if ($null -eq $d -or $d.Sp -ne $sender) { return }
    $sc = 1.0
    if ($dpiK) { $sc = [double]$dpiK }
    $pos = [System.Windows.Forms.Cursor]::Position
    if ($sender -eq $spV1) {
        $dx = ($pos.X - $d.Pos.X) / $sc
        $base = $d.ColW0
        if ($base -le 0) { $base = 940 }
        $Cfg.ColW = [math]::Max(380, ($base + $dx))
    } else {
        $dy = ($pos.Y - $d.Pos.Y) / $sc
        $t = $sender.Tag
        $h = @{ Set = $d.H0.Set; Act = $d.H0.Act; St = $d.H0.St }
        $up = [double]$h[$t.Up] + $dy
        if ($up -lt 44) { $dy = 44 - $h[$t.Up]; $up = 44 }
        if (-not $t.Flex) {
            $dn = [double]$h[$t.Down] - $dy
            if ($dn -lt 44) { $dy = $h[$t.Down] - 44; $up = [double]$h[$t.Up] + $dy; $dn = 44 }
            $h[$t.Down] = $dn
        }
        $h[$t.Up] = $up
        Put-SecH $h
    }
    Arrange-Sections
}
$dragUp = {
    param($sender, $e)
    if ($S.Drag) { $S.Drag = $null; $sender.Capture = $false; $sender.BackColor = $thBg; Save-Settings }
}
foreach ($c in @($spH1, $spH2, $spH3, $spV1)) {
    $c.Add_MouseDown($dragDown)
    $c.Add_MouseMove($dragMove)
    $c.Add_MouseUp($dragUp)
}

$FoldBtns = @{}
$GripBtns = @{}
foreach ($k in @('Set', 'Act', 'St', 'Log')) {
    $fb = New-Btn 'v' 0 0 24 18
    $fb.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $fb.Tag = 'keep'
    $fb.Name = $k
    $fb.Visible = $false
    $SecMap[$k].Ctl.Controls.Add($fb)
    $FoldBtns[$k] = $fb
    $fb.Add_Click({ param($sender, $e) Set-Fold ([string]$sender.Name) (-not $S.Fold[[string]$sender.Name]); Arrange-Sections })
    $tt.SetToolTip($fb, 'Fold or unfold this box')
}
foreach ($k in @('Set', 'Act', 'St')) {
    $gr = New-Object System.Windows.Forms.Panel
    $gr.Tag = 'keep'
    $gr.Name = $k
    $gr.Cursor = [System.Windows.Forms.Cursors]::SizeNS
    $gr.Visible = $false
    $gr.Add_Paint({
        param($sender, $e)
        $pen = New-Object System.Drawing.Pen($thPink, 2)
        $w = $sender.Width - 2; $hh = $sender.Height - 2
        $e.Graphics.DrawLine($pen, $w, 2, 2, $hh)
        $e.Graphics.DrawLine($pen, $w, [int]($hh / 2 + 2), [int]($w / 2 + 2), $hh)
        $pen.Dispose()
    })
    $gr.Add_MouseDown({ param($sender, $e) $S.Drag = @{ Sp = $sender; Pos = [System.Windows.Forms.Cursor]::Position; H0 = (Get-SecH); ColW0 = 0.0 }; $sender.Capture = $true })
    $gr.Add_MouseMove({
        param($sender, $e)
        $d = $S.Drag
        if ($null -eq $d -or $d.Sp -ne $sender) { return }
        $sc = 1.0
        if ($dpiK) { $sc = [double]$dpiK }
        $dy = ([System.Windows.Forms.Cursor]::Position.Y - $d.Pos.Y) / $sc
        $h = @{ Set = $d.H0.Set; Act = $d.H0.Act; St = $d.H0.St }
        $key = [string]$sender.Name
        $h[$key] = [math]::Max(44, ($d.H0[$key] + $dy))
        Put-SecH $h
        Arrange-Sections
    })
    $gr.Add_MouseUp({ param($sender, $e) if ($S.Drag) { $S.Drag = $null; $sender.Capture = $false; Save-Settings } })
    $SecMap[$k].Ctl.Controls.Add($gr)
    $GripBtns[$k] = $gr
}

$capDrag = @{ Set = 'Act'; Act = 'St'; St = 'Log' }
foreach ($k in @('Set', 'Act', 'St')) {
    $gc = $SecMap[$k].Ctl
    $gc.Tag = $k
    $gc.Add_MouseMove({
        param($sender, $e)
        $sc = 1.0
        if ($dpiK) { $sc = [double]$dpiK }
        $key = [string]$sender.Tag
        $d = $S.Drag
        if ($d -and $d.Cap -eq $key) {
            $dy = ([System.Windows.Forms.Cursor]::Position.Y - $d.Pos.Y) / $sc
            $h = @{ Set = $d.H0.Set; Act = $d.H0.Act; St = $d.H0.St }
            $h[$key] = [math]::Max(44, ($d.H0[$key] + $dy))
            Put-SecH $h
            Arrange-Sections
            return
        }
        if ([string]$Cfg.Resize -ne 'Drag' -and [string]$Cfg.Resize -ne '') { $sender.Cursor = [System.Windows.Forms.Cursors]::Default; return }
        if ($e.Y -lt [int](16 * $sc)) { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeNS } else { $sender.Cursor = [System.Windows.Forms.Cursors]::Default }
    })
    $gc.Add_MouseDown({
        param($sender, $e)
        $sc = 1.0
        if ($dpiK) { $sc = [double]$dpiK }
        $mode = [string]$Cfg.Resize
        if ($mode -ne '' -and $mode -ne 'Drag') { return }
        if ($e.Y -lt [int](16 * $sc) -and $e.Button -eq 'Left') {
            $S.Drag = @{ Cap = [string]$sender.Tag; Sp = $sender; Pos = [System.Windows.Forms.Cursor]::Position; H0 = (Get-SecH); ColW0 = 0.0 }
            $sender.Capture = $true
        }
    })
    $gc.Add_MouseUp({
        param($sender, $e)
        if ($S.Drag -and $S.Drag.Cap) { $S.Drag = $null; $sender.Capture = $false; Save-Settings }
    })
}
foreach ($c in @($btnRzA, $btnRzB, $btnRzC)) {
    $c.Add_Click({ param($sender, $e) Guard { Set-ResizeMode ([string]$sender.Tag) } })
}
$body.Add_Resize({ try { Arrange-Sections } catch {} })

$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender, $e)
    $k = [string]$e.KeyCode
    if ($k -eq 'F5') { $e.Handled = $true; Guard { Run-Full } }
    elseif ($k -eq 'F6') { $e.Handled = $true; Guard { Run-Sync } }
    elseif ($k -eq 'F7') { $e.Handled = $true; Guard { Run-Shaders } }
    elseif ($k -eq 'F8') { $e.Handled = $true; Guard { Run-Launch } }
})

# ---- Wiring ----
$btnFull.Add_Click({ Guard { Run-Full } })
$btnShaders.Add_Click({ Guard { Run-Shaders } })
$btnSync.Add_Click({ Guard { Run-Sync } })
$btnLaunch.Add_Click({ Guard { Run-Launch } })
$btnCheck.Add_Click({ Guard { Run-Check } })
$btnMigrate.Add_Click({ Guard {
    Read-UI
    $r = [System.Windows.Forms.MessageBox]::Show(('Move the old cache and data files from ' + $Cfg.OldDir + ' to the cache and data folders above?'), 'Move old files', 'YesNo', 'Question')
    if ($r -eq 'Yes') { Run-Migrate }
} })
$btnCache.Add_Click({ Guard {
    Read-UI
    if (-not (Test-Path -LiteralPath $Cfg.CacheDir)) { New-Item -ItemType Directory -Force -Path $Cfg.CacheDir | Out-Null }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Cfg.CacheDir + '"')
} })
$btnClear.Add_Click({ $rtb.Clear() })
$btnZip.Add_Click({ Guard { Choose-Zip } })
$btnMusic.Add_Click({ Guard { Music-Toggle } })
$btnPick.Add_Click({ Guard { Music-Pick } })
$cmbTrack.Add_SelectedIndexChanged({ Guard { if ($cmbTrack.SelectedIndex -ge 0) { Music-Select $cmbTrack.SelectedIndex } } })
$btnNext.Add_Click({ Guard { $cmbTrack.SelectedIndex = (($cmbTrack.SelectedIndex + 1) % $cmbTrack.Items.Count) } })
$btnPick.Add_MouseUp({ param($sender, $e) if ($e.Button -eq 'Right') { Guard { Music-Reset } } })
$trkVol.Add_Scroll({
    $Cfg.MusicVol = [int]$trkVol.Value
    try { if ($S.Player) { $S.Player.Volume = [double]($trkVol.Value / 100.0) } } catch {}
})
$trkVol.Add_MouseUp({ Guard { Save-Settings } })
$btnStop.Add_Click({ Guard { Stop-All } })
$btnSave.Add_Click({ Guard { Read-UI; Save-Settings; Write-Log 'Settings saved.' $colGreen } })

$form.Add_FormClosing({
    param($sender, $e)
    if ($S.Running) {
        $r = [System.Windows.Forms.MessageBox]::Show('A task is still running. Stop it and exit?', 'Hyphen Manager', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        Stop-All
    }
    try { $timer.Stop() } catch {}
    try { $musicTimer.Stop(); Music-Stop; if ($S.Player) { $S.Player.Close() } } catch {}
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({ Tick-Guard })

$musicTimer = New-Object System.Windows.Forms.Timer
$musicTimer.Interval = 150
$musicTimer.Add_Tick({ try { Music-Tick } catch {} })

$form.Add_Shown({
    Guard {
        try { [void][Native]::ShowWindow([Native]::GetConsoleWindow(), 0) } catch {}
        Write-Log ('Folder: ' + $ScriptDir) $colGray
        if ($FirstRun) { Write-Log 'First run: check the folders in Settings, then press Full Setup.' $colBlue }
        else { Write-Log 'Ready.' $colGreen }
        if (-not $HaveGit) { Write-Log 'Note: git was not found, so updating from GitHub is disabled.' $colAmber }
        Apply-Env
        Update-RepoStatus
        Refresh-Procs
        Start-Scan
        Start-BgFetch $false
        [Synth]::RenderAsync($MusicTracks)
        $musicTimer.Start()
        if ($Cfg.MusicOn) { Music-Start }
        $timer.Start()
    }
})

$form.BackColor = $thBg
$body.BackColor = $thBg
Apply-Theme $body
Apply-Theme $banner
Music-UI
$btnFull.BackColor = $thPink
$btnFull.ForeColor = [System.Drawing.Color]::White
$btnFull.FlatAppearance.BorderColor = $thOrange
$btnFull.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(255, 100, 170)
$btnLaunch.BackColor = $thOrange
$btnLaunch.ForeColor = [System.Drawing.Color]::FromArgb(35, 10, 45)
$btnLaunch.FlatAppearance.BorderColor = $thPink
$btnLaunch.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(255, 175, 95)
$btnStop.BackColor = [System.Drawing.Color]::FromArgb(200, 30, 70)
$btnStop.ForeColor = [System.Drawing.Color]::White
$btnStop.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(255, 90, 120)
$btnStop.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(230, 50, 90)
$lblLive.ForeColor = $colGray
$lblStep.ForeColor = $thCyan
foreach ($c in @($capOv, $capSt, $capFi, $lblEtaFile)) { $c.ForeColor = $colGray }
try { Arrange-Sections } catch {}
$gdi = $form.CreateGraphics()
$dpiK = [double]$gdi.DpiX / 96.0
$gdi.Dispose()
if ($dpiK -gt 1.01) { $form.Scale((New-Object System.Drawing.SizeF([single]$dpiK, [single]$dpiK))) }
$form.MinimumSize = New-Object System.Drawing.Size(700, 500)
$form.Add_Shown({
    try {
        $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
        if ($form.Height -gt $wa.Height) { $form.Height = $wa.Height }
        if ($form.Width -gt $wa.Width) { $form.Width = $wa.Width }
        $form.Left = $wa.Left + [int](($wa.Width - $form.Width) / 2)
        $form.Top = $wa.Top + [int](($wa.Height - $form.Height) / 2)
    } catch {}
})

[System.Windows.Forms.Application]::Run($form)
