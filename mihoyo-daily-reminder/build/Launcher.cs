// 米哈游每日助手 · 独立宿主
//
// 编译成一个带图标的 Windows 程序（无控制台窗口）。它把 Windows PowerShell 引擎
// 加载到自己的进程里跑脚本，所以任务管理器里看到的就是「米哈游每日助手.exe」，
// 不会再在旁边多出一个 powershell.exe。
//
//   （无参数）        -> 桌面程序 desktop-app.ps1
//   --reminder ...    -> 23:30 的提醒弹窗 daily-reminder.ps1
//   --watch ...       -> 盯着游戏的看门进程 watch-games.ps1
//   --desktop ...     -> 显式指定桌面程序
//   --script X.ps1 .. -> 跑任意脚本
//
// 界面逻辑仍然全在 .ps1 里，这个 exe 只负责把脚本跑起来。
using System;
using System.Collections.Generic;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

internal static class Launcher
{
    private const string AppTitle = "米哈游每日助手";
    private const string DesktopScript = "desktop-app.ps1";
    private const string ReminderScript = "daily-reminder.ps1";
    private const string WatchScript = "watch-games.ps1";

    [STAThread]
    private static int Main(string[] args)
    {
        string baseDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);

        string scriptName = DesktopScript;
        // 传给脚本的原始参数（解析成命名参数后交给 PowerShell）
        List<string> rawArgs = new List<string>();

        int i = 0;
        while (i < args.Length)
        {
            string current = args[i];
            if (current == "--desktop") { scriptName = DesktopScript; i++; continue; }
            if (current == "--reminder") { scriptName = ReminderScript; i++; continue; }
            if (current == "--watch") { scriptName = WatchScript; i++; continue; }
            if (current == "--script")
            {
                if (i + 1 < args.Length) { scriptName = args[i + 1]; }
                i += 2;
                continue;
            }
            rawArgs.Add(current);
            i++;
        }

        string scriptPath = Path.Combine(baseDir, scriptName);
        if (!File.Exists(scriptPath))
        {
            MessageBox.Show(
                "找不到 " + scriptName + "。\n\n请把这个程序和脚本文件放在同一个文件夹里再运行。",
                AppTitle,
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return 1;
        }

        try
        {
            return RunScript(baseDir, scriptPath, rawArgs);
        }
        catch (Exception ex)
        {
            WriteLog("启动或者运行失败：" + ex.ToString());
            WriteLog("  启动参数：" + string.Join(" ", args));
            // 只有双击桌面程序时才弹框；--reminder / --watch 这些后台任务只写日志，
            // 不然它们卡在对话框上会一直占着文件、还挡着用户。
            if (scriptName == DesktopScript && args.Length == 0)
            {
                MessageBox.Show(
                    "启动失败：" + ex.Message + "\n\n日志在 %TEMP%\\mihoyo-daily-reminder.log。",
                    AppTitle,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
            return 1;
        }
    }

    private static int RunScript(string baseDir, string scriptPath, List<string> rawArgs)
    {
        // CreateDefault2 = 模块化的核心会话，常用命令和模块自动加载都在
        InitialSessionState state = InitialSessionState.CreateDefault2();
        state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
        // 用当前这个 STA 线程跑脚本：WPF 界面才能开出来
        state.ThreadOptions = PSThreadOptions.UseCurrentThread;

        Directory.SetCurrentDirectory(baseDir);

        using (Runspace runspace = RunspaceFactory.CreateRunspace(state))
        {
            runspace.Open();
            using (PowerShell shell = PowerShell.Create())
            {
                shell.Runspace = runspace;
                // 用「命令」方式调用，脚本里的 $PSScriptRoot / $PSCommandPath 才正常
                shell.AddCommand(scriptPath);
                AddScriptArguments(shell, rawArgs);
                shell.Invoke();

                bool failed = false;
                foreach (ErrorRecord record in shell.Streams.Error)
                {
                    failed = true;
                    WriteLog("运行时错误：" + record.ToString());
                }
                return failed ? 1 : 0;
            }
        }
    }

    /// <summary>
    /// 把 "-Name value" 这种命令行拆成"命名参数"交给脚本。
    /// 直接 AddArgument("-Name") 会被 PowerShell 当成位置参数，参数名就没用了。
    ///   -DelaySeconds 600         -> 参数 DelaySeconds = 600
    ///   -ProcessNames A,B         -> 参数 ProcessNames = "A,B"
    ///   -Force                    -> 开关参数（后面没有值就是开关）
    ///   值里带 "-" 开头的（比如负数）在咱们自己的脚本里用不到，不管。
    /// </summary>
    private static void AddScriptArguments(PowerShell shell, List<string> rawArgs)
    {
        int index = 0;
        while (index < rawArgs.Count)
        {
            string token = rawArgs[index];

            if (token.Length > 1 && token[0] == '-')
            {
                string name = token.Substring(1);
                string inlineValue = null;
                int colon = name.IndexOf(':');
                if (colon >= 0)
                {
                    inlineValue = name.Substring(colon + 1);
                    name = name.Substring(0, colon);
                }

                List<string> values = new List<string>();
                if (inlineValue != null) { values.Add(inlineValue); }

                index++;
                while (index < rawArgs.Count && !(rawArgs[index].Length > 1 && rawArgs[index][0] == '-'))
                {
                    values.Add(rawArgs[index]);
                    index++;
                }

                if (values.Count == 0)
                {
                    shell.AddParameter(name);
                }
                else if (values.Count == 1)
                {
                    shell.AddParameter(name, values[0]);
                }
                else
                {
                    shell.AddParameter(name, values.ToArray());
                }
                continue;
            }

            shell.AddArgument(token);
            index++;
        }
    }

    private static void WriteLog(string message)
    {
        try
        {
            string logPath = Path.Combine(Path.GetTempPath(), "mihoyo-daily-reminder.log");
            string line = string.Format(
                "{0:yyyy-MM-dd HH:mm:ss} [PID {1}] {2}{3}",
                DateTime.Now,
                System.Diagnostics.Process.GetCurrentProcess().Id,
                message,
                Environment.NewLine);
            File.AppendAllText(logPath, line, new UTF8Encoding(false));
        }
        catch
        {
            // 记日志失败不影响主流程
        }
    }
}
