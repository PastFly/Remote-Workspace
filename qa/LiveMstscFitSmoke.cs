using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

internal static class LiveMstscFitSmoke
{
    private static readonly Size Desktop = new Size(1067, 662);
    private static readonly Size EnlargedViewport = new Size(1461, 767);
    private static readonly Size ReducedViewport = new Size(900, 575);
    private static readonly Color[] Markers =
    {
        Color.FromArgb(213, 46, 41), Color.FromArgb(45, 181, 107),
        Color.FromArgb(41, 91, 237), Color.FromArgb(236, 197, 49)
    };
    private static Type _native;
    private static Type _viewportType;
    private static Process _client;
    private static IntPtr _shell;
    private static IntPtr _anchor;
    private static IntPtr _stage;
    private static bool _closeClient;

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            bool baseline = false;
            int fixturePid = 0;
            for (int i = 1; i < args.Length; i++)
            {
                if (args[i] == "--expect-084-limited" && !baseline) baseline = true;
                else if (args[i] != "--attach" || fixturePid != 0 || ++i >= args.Length ||
                    !int.TryParse(args[i], out fixturePid) || fixturePid <= 0) throw Usage();
            }
            if (args.Length == 0) throw Usage();
            if (SetThreadDpiAwarenessContext(new IntPtr(-4)) == IntPtr.Zero)
                throw new InvalidOperationException("Per-monitor DPI awareness is unavailable.");
            if (!Environment.UserInteractive || Process.GetCurrentProcess().SessionId == 0)
                throw new InvalidOperationException("The probe requires an interactive Windows desktop.");
            var application = Assembly.LoadFrom(Path.GetFullPath(args[0]));
            _native = application.GetType("RemoteWorkspace.MstscWindow", true);
            _viewportType = application.GetType("RemoteWorkspace.MstscViewport", true);
            using (var form = new Form
            {
                AutoScaleMode = AutoScaleMode.None,
                FormBorderStyle = FormBorderStyle.None,
                StartPosition = FormStartPosition.Manual,
                ShowInTaskbar = false
            })
            using (var viewport = (Panel)Activator.CreateInstance(_viewportType, true))
            {
                viewport.Dock = DockStyle.Fill;
                _viewportType.GetProperty("DesktopSize", BindingFlags.Instance | BindingFlags.NonPublic)
                    .SetValue(viewport, Desktop);
                _viewportType.GetProperty("AutoFitViewport", BindingFlags.Instance | BindingFlags.NonPublic)
                    .SetValue(viewport, true);
                form.Controls.Add(viewport);
                form.Location = Screen.PrimaryScreen.Bounds.Location;
                form.ClientSize = Desktop;
                form.Show();
                _anchor = viewport.Handle;
                try
                {
                    _client = fixturePid > 0 ? Process.GetProcessById(fixturePid) : Launch(application, Bounds(_anchor));
                    if (!string.Equals(_client.ProcessName, "mstsc", StringComparison.OrdinalIgnoreCase) ||
                        _client.SessionId != Process.GetCurrentProcess().SessionId)
                        throw new InvalidOperationException("The selected process is not Windows Remote Desktop Connection in this session.");
                    Console.WriteLine("LIVE_MSTSC_PID=" + _client.Id);
                    WaitUntil(() =>
                    {
                        _shell = (IntPtr)Invoke(_native, "FindDesktop", _client.Id);
                        return _shell != IntPtr.Zero;
                    }, 90000, "inbox mstsc created its ready desktop window");
                    Invoke(_native, "Attach", _shell, _anchor, _client.Id);
                    _closeClient = true;
                    _stage = GetParent(_shell);
                    Require(GetParent(_stage) == _anchor, "stock shell is attached to the production clipping stage");

                    ObserveFrame(form, Desktop, Desktop, 90000, "Initial");
                    form.TopMost = true;
                    form.Activate();
                    form.ClientSize = EnlargedViewport;
                    Invoke(_native, "Place", _shell, _anchor, true);
                    ObserveFrame(form, EnlargedViewport, baseline ? Desktop : new Size(1236, 767), 12000, "Growth");
                    form.ClientSize = ReducedViewport;
                    ObserveFrame(form, ReducedViewport, new Size(900, 558), 12000, "Shrink");
                    Require(SameConnection(), "initial view, growth and shrink used the original mstsc process and attached shell");
                }
                catch
                {
                    if (_client != null)
                    {
                        var geometry = application.GetType("RemoteWorkspace.SessionGeometry", true);
                        Console.WriteLine((string)Invoke(geometry, "Describe", _anchor, _client.Id, Desktop));
                    }
                    throw;
                }
                finally
                {
                    if (_closeClient && _client != null && !_client.HasExited)
                    {
                        Invoke(_native, "DetachForClose", _anchor, _client.Id);
                        if (!_client.WaitForExit(1500)) _client.Kill();
                    }
                    _client?.Dispose();
                }
            }
            Console.WriteLine("LIVE_MSTSC_FIT=PASS");
            return 0;
        }
        catch (Exception error)
        {
            Console.WriteLine("LIVE_MSTSC_FIT=FAIL " + error.GetBaseException().Message);
            return 1;
        }
    }

    private static ArgumentException Usage() => new ArgumentException(
        "Pass RemoteWorkspace.exe and optionally --expect-084-limited and --attach <disposable mstsc PID>.");

    private static Process Launch(Assembly application, Rectangle viewport)
    {
        string endpoint = Environment.GetEnvironmentVariable("RW_LAB_ENDPOINT") ?? string.Empty;
        int colon = endpoint.LastIndexOf(':');
        if (colon <= 0 || !IPAddress.TryParse(endpoint.Substring(0, colon).Trim('[', ']'), out IPAddress address) ||
            !IPAddress.IsLoopback(address) || !int.TryParse(endpoint.Substring(colon + 1), out int port) || port < 1 || port > 65535)
            throw new InvalidOperationException("Set RW_LAB_ENDPOINT to an isolated loopback RDP listener and port.");
        Type profileType = application.GetType("RemoteWorkspace.Profile", true);
        object profile = Activator.CreateInstance(profileType);
        profileType.GetProperty("Host").SetValue(profile, address.ToString());
        profileType.GetProperty("Port").SetValue(profile, port);
        profileType.GetProperty("User").SetValue(profile, Environment.GetEnvironmentVariable("RW_LAB_GUEST_USER") ?? string.Empty);
        Type rdp = application.GetType("RemoteWorkspace.NativeRdp", true);
        var process = (Process)Invoke(rdp, "StartTabbed", profile, false, viewport.Width, viewport.Height, viewport.X, viewport.Y, Desktop);
        _closeClient = true;
        return process;
    }

    private static void ObserveFrame(Form form, Size viewport, Size expected, int timeout, string phase)
    {
        Rectangle? observed = null;
        var wanted = new Rectangle((viewport.Width - expected.Width) / 2, (viewport.Height - expected.Height) / 2,
            expected.Width, expected.Height);
        try
        {
            WaitUntil(() =>
            {
                if (!SameConnection()) throw new InvalidOperationException("The authenticated mstsc process or shell changed.");
                if (!(bool)Invoke(_native, "Place", _shell, _anchor, false)) return false;
                if (Bounds(_anchor).Size != viewport) throw new InvalidOperationException("The host could not realize the requested test viewport.");
                using (Bitmap capture = CaptureViewport(form, viewport)) observed = LocateMarkers(capture);
                return observed.HasValue && NearBounds(observed.Value, wanted, 4);
            }, timeout, phase + " pixels show the complete centered guest at the expected proportional size");
        }
        finally
        {
            Console.WriteLine("{0}: viewport={1}; stage={2}; measured-marker={3}; expected={4}", phase, viewport, Bounds(_stage).Size,
                observed?.ToString() ?? "not-visible", wanted);
        }
    }

    // Move the unchanged viewport under the physical monitor when the Windows
    // runner only offers 1024x768. All sampled pixels remain inside the fixture.
    private static Bitmap CaptureViewport(Form form, Size viewport)
    {
        Rectangle screen = Screen.PrimaryScreen.Bounds;
        var capture = new Bitmap(viewport.Width, viewport.Height);
        Point savedPosition = form.Location;
        try
        {
            using (Graphics target = Graphics.FromImage(capture))
            {
                for (int y = 0; y < viewport.Height; y += screen.Height)
                for (int x = 0; x < viewport.Width; x += screen.Width)
                {
                    form.Location = new Point(screen.X - x, screen.Y - y);
                    Application.DoEvents();
                    DwmFlush();
                    Rectangle current = Bounds(_anchor);
                    var area = new Rectangle(current.X + x, current.Y + y,
                        Math.Min(screen.Width, viewport.Width - x), Math.Min(screen.Height, viewport.Height - y));
                    if (!screen.Contains(area)) throw new InvalidOperationException("The viewport tile is outside the physical screen.");
                    target.CopyFromScreen(area.Location, new Point(x, y), area.Size);
                }
            }
            return capture;
        }
        catch
        {
            capture.Dispose();
            throw;
        }
        finally { form.Location = savedPosition; }
    }

    private static Rectangle? LocateMarkers(Bitmap image)
    {
        int left = image.Width, right = -1, top = image.Height, bottom = -1;
        for (int x = 0; x < image.Width; x++)
        {
            Color pixel = image.GetPixel(x, image.Height / 3);
            if (!NearColor(pixel, Markers[0]) && !NearColor(pixel, Markers[1])) continue;
            left = Math.Min(left, x);
            right = x;
        }
        for (int y = 0; y < image.Height; y++)
        {
            Color pixel = image.GetPixel(image.Width / 3, y);
            if (!NearColor(pixel, Markers[0]) && !NearColor(pixel, Markers[2])) continue;
            top = Math.Min(top, y);
            bottom = y;
        }
        if (right - left < 100 || bottom - top < 100) return null;
        if (!NearColor(image.GetPixel(left + 10, top + 10), Markers[0]) ||
            !NearColor(image.GetPixel(right - 10, top + 10), Markers[1]) ||
            !NearColor(image.GetPixel(left + 10, bottom - 10), Markers[2]) ||
            !NearColor(image.GetPixel(right - 10, bottom - 10), Markers[3])) return null;
        return Rectangle.FromLTRB(left, top, right + 1, bottom + 1);
    }

    private static bool NearColor(Color actual, Color expected) => Math.Abs(actual.R - expected.R) < 28 &&
        Math.Abs(actual.G - expected.G) < 28 && Math.Abs(actual.B - expected.B) < 28;

    private static bool NearBounds(Rectangle actual, Rectangle expected, int tolerance) =>
        Math.Abs(actual.Left - expected.Left) <= tolerance && Math.Abs(actual.Top - expected.Top) <= tolerance &&
        Math.Abs(actual.Right - expected.Right) <= tolerance && Math.Abs(actual.Bottom - expected.Bottom) <= tolerance;

    private static bool SameConnection() => !_client.HasExited && GetParent(_shell) == _stage && GetParent(_stage) == _anchor &&
        GetWindowThreadProcessId(_shell, out uint owner) != 0 && owner == (uint)_client.Id;

    private static object Invoke(Type receiver, string method, params object[] args) =>
        receiver.GetMethod(method, BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, args);

    private static void WaitUntil(Func<bool> condition, int milliseconds, string description)
    {
        var clock = Stopwatch.StartNew();
        do
        {
            Application.DoEvents();
            if (condition()) { Console.WriteLine("PASS " + description); return; }
            Thread.Sleep(100);
        } while (clock.ElapsedMilliseconds < milliseconds);
        throw new TimeoutException(description);
    }

    private static void Require(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException(description);
        Console.WriteLine("PASS " + description);
    }

    private static Rectangle Bounds(IntPtr window)
    {
        var origin = Point.Empty;
        if (!GetClientRect(window, out Rect client) || !ClientToScreen(window, ref origin)) throw new Win32Exception();
        return new Rectangle(origin.X, origin.Y, client.Right, client.Bottom);
    }

    [StructLayout(LayoutKind.Sequential)] private struct Rect { internal int Left, Top, Right, Bottom; }
    [DllImport("user32")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32")] private static extern IntPtr GetParent(IntPtr window);
    [DllImport("user32")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32", SetLastError = true)] private static extern bool GetClientRect(IntPtr window, out Rect bounds);
    [DllImport("user32", SetLastError = true)] private static extern bool ClientToScreen(IntPtr window, ref Point point);
    [DllImport("dwmapi")] private static extern int DwmFlush();
}
