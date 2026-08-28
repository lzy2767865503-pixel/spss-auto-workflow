using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace StatFlow.Workbench.Desktop;

internal sealed record BackendReady(Uri Url, string ApiToken);

internal sealed class BackendHost : IAsyncDisposable
{
    private Process? _process;
    private KillOnCloseJob? _job;

    private static void TerminateAndConfirm(Process process, string failureMessage)
    {
        if (!process.HasExited)
        {
            Exception? killFailure = null;
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException) when (process.HasExited)
            {
                // The process exited between the state check and Kill.
            }
            catch (Exception error)
            {
                // Still wait on the exact process handle. A concurrent exit is
                // acceptable; a live process after the deadline is not.
                killFailure = error;
            }
            if (!process.WaitForExit(15_000) || !process.HasExited)
            {
                throw killFailure is null
                    ? new TimeoutException(failureMessage)
                    : new TimeoutException(failureMessage, killFailure);
            }
        }
        else
        {
            // Complete native process-handle bookkeeping before disposal.
            process.WaitForExit();
        }
    }

    public async Task<BackendReady> StartAsync(string dataDirectory, CancellationToken cancellationToken)
    {
        if (_process is not null)
        {
            throw new InvalidOperationException("Backend has already been started.");
        }

        var executable = Path.Combine(AppContext.BaseDirectory, "backend", "statflow-backend.exe");
        if (!File.Exists(executable))
        {
            throw new FileNotFoundException("缺少本地分析服务，请重新安装应用。", executable);
        }

        Directory.CreateDirectory(dataDirectory);
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = AppContext.BaseDirectory,
        };
        startInfo.ArgumentList.Add("--port");
        startInfo.ArgumentList.Add("0");
        startInfo.ArgumentList.Add("--data-dir");
        startInfo.ArgumentList.Add(dataDirectory);
        startInfo.ArgumentList.Add("--parent-pid");
        startInfo.ArgumentList.Add(Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture));

        _job = KillOnCloseJob.Create();
        _process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        _process.ErrorDataReceived += (_, _) =>
        {
            // Drain stderr without forwarding paths or tokens into the desktop UI.
        };
        if (!_process.Start())
        {
            _process.Dispose();
            _process = null;
            _job.Dispose();
            _job = null;
            throw new InvalidOperationException("无法启动本地分析服务。");
        }
        try
        {
            _job.Assign(_process);
        }
        catch
        {
            try
            {
                TerminateAndConfirm(_process, "本地分析服务启动失败后仍未退出。");
            }
            finally
            {
                _process.Dispose();
                _process = null;
                _job.Dispose();
                _job = null;
            }
            throw;
        }

        _process.BeginErrorReadLine();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(90));
        try
        {
            while (!timeout.IsCancellationRequested)
            {
                var line = await _process.StandardOutput.ReadLineAsync(timeout.Token);
                if (line is null)
                {
                    throw new InvalidOperationException("本地分析服务在准备完成前退出。");
                }

                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (root.TryGetProperty("event", out var eventName) && eventName.GetString() == "ready")
                {
                    var urlText = root.GetProperty("url").GetString();
                    var token = root.GetProperty("apiToken").GetString();
                    if (!Uri.TryCreate(urlText, UriKind.Absolute, out var url) ||
                        url.Scheme != Uri.UriSchemeHttp ||
                        url.Host != "127.0.0.1" ||
                        string.IsNullOrWhiteSpace(token) ||
                        token.Length < 32)
                    {
                        throw new InvalidOperationException("本地分析服务返回了无效的安全参数。");
                    }
                    return new BackendReady(url, token);
                }
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException("本地分析服务启动超时。");
        }

        throw new TimeoutException("本地分析服务启动超时。");
    }

    public ValueTask DisposeAsync()
    {
        if (_process is null)
        {
            _job?.Dispose();
            _job = null;
            return ValueTask.CompletedTask;
        }

        Exception? shutdownFailure = null;
        try
        {
            TerminateAndConfirm(_process, "本地分析服务在关闭时未于 15 秒内退出。");
        }
        catch (InvalidOperationException)
        {
            // The process exited between the checks.
        }
        catch (Exception error)
        {
            shutdownFailure = error;
        }
        finally
        {
            _process.Dispose();
            _process = null;
            _job?.Dispose();
            _job = null;
        }
        if (shutdownFailure is not null)
        {
            throw shutdownFailure;
        }
        return ValueTask.CompletedTask;
    }
}
