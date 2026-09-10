// 米哈游每日助手 · 桌面程序的启动器
// 编译成一个带图标的 Windows 程序（无控制台窗口），双击就直接打开桌面程序。
// 真正的界面逻辑在 desktop-app.ps1 里，这个 exe 只负责安静地把脚本跑起来。
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

internal static class Launcher
{
    private const string ScriptName = "desktop-app.ps1";
    private const string AppTitle = "米哈游每日助手";

    [STAThread]
    private static void Main()
    {
        string baseDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string scriptPath = Path.Combine(baseDir, ScriptName);

        if (!File.Exists(scriptPath))
        {
            MessageBox.Show(
                "找不到 " + ScriptName + "。\n\n请把这个程序和脚本文件放在同一个文件夹里再运行。",
                AppTitle,
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return;
        }

        string windowsPowerShell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");

        if (!File.Exists(windowsPowerShell))
        {
            MessageBox.Show(
                "找不到 Windows PowerShell，无法启动。",
                AppTitle,
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }

        ProcessStartInfo startInfo = new ProcessStartInfo(windowsPowerShell);
        startInfo.Arguments = "-NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File \"" + scriptPath + "\"";
        startInfo.WorkingDirectory = baseDir;
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;

        try
        {
            Process.Start(startInfo);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "启动失败：" + ex.Message,
                AppTitle,
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}
