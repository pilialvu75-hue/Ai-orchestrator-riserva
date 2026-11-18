using System.Drawing;
using System.Windows.Forms;

namespace AdsKill.Windows;

public sealed class MainForm : Form
{
    private readonly Label _status;
    private readonly Label _rules;
    private readonly Label _message;
    private readonly Button _enable;
    private readonly Button _disable;
    private readonly Button _reward;
    private readonly System.Windows.Forms.Timer _timer;
    private DateTimeOffset? _rewardDeadline;

    public MainForm()
    {
        Text = "Ads Kill — Windows (beta)";
        Width = 635;
        Height = 565;
        MinimumSize = new Size(580, 465);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(247, 250, 253);

        var outer = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            Padding = new Padding(24)
        };
        Controls.Add(outer);

        Label AddLabel(string text, int size, bool bold = false, int height = 44)
        {
            var label = new Label
            {
                AutoSize = false,
                Width = 545,
                Height = height,
                Text = text,
                Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular),
                ForeColor = Color.FromArgb(25, 45, 67),
                Margin = new Padding(0, 5, 0, 7)
            };
            outer.Controls.Add(label);
            return label;
        }

        AddLabel("Ads Kill", 25, true, 49);
        AddLabel("Protezione pubblicità DNS con file HOSTS • Windows 11 x64", 11, false, 34);
        _status = AddLabel("Verifica protezione...", 17, true, 39);
        _rules = AddLabel("Regole: " + HostsSections.Domains.Length + " domini", 11, false, 32);

        var buttons = new FlowLayoutPanel
        {
            Width = 545, Height = 52, FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false, Margin = new Padding(0, 8, 0, 8)
        };
        outer.Controls.Add(buttons);

        Button AddButton(string caption, int width)
        {
            var button = new Button
            {
                Text = caption,
                AutoSize = false,
                Width = width,
                Height = 42,
                FlatStyle = FlatStyle.System,
                Font = new Font("Segoe UI", 10)
            };
            buttons.Controls.Add(button);
            return button;
        }

        _enable = AddButton("Attiva blocco", 150);
        _disable = AddButton("Disattiva blocco", 158);
        _reward = AddButton("Ricompensa: 60 s", 175);
        _enable.Click += (_, _) => ChangeProtection(true);
        _disable.Click += (_, _) =>
        {
            _rewardDeadline = null;
            ChangeProtection(false);
        };
        _reward.Click += (_, _) => BeginReward();

        _message = AddLabel("", 11, false, 73);
        AddLabel("Nessuna VPN, driver, estensione browser o account richiesti.", 10, false, 37);
        AddLabel("Il filtro usa 0.0.0.0 e :: per domini pubblicitari espliciti. "
            + "Non elimina gli annunci incorporati nei video e può non funzionare con DNS sicuri o cache proprie.",
            10, false, 72);
        AddLabel("Le modifiche richiedono autorizzazione amministratore. "
            + "Ads Kill conserva il file HOSTS originale in C:\\ProgramData\\AdsKill\\backups. "
            + "Il pulsante Disattiva rimuove SOLO le proprie righe.",
            10, false, 78);

        _timer = new System.Windows.Forms.Timer { Interval = 1000 };
        _timer.Tick += (_, _) => TickTimer();
        _timer.Start();
        RefreshState();
    }

    private void ChangeProtection(bool protect)
    {
        try
        {
            var result = HostsStore.SetProtected(protect);
            _message.Text = result.Changed
                ? (protect ? "Protezione attivata." : "Protezione disattivata.")
                    + " Backup: " + result.BackupPath
                : "Nessuna modifica: lo stato era già quello richiesto.";
            if (result.DnsWarning is not null) _message.Text += "\n" + result.DnsWarning;
        }
        catch (Exception ex)
        {
            _message.Text = "Operazione non completata.";
            MessageBox.Show(this, ex.Message,
                "Ads Kill — modifica non riuscita", MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
        RefreshState();
    }

    private void BeginReward()
    {
        try
        {
            HostsStore.SetProtected(false);
            _rewardDeadline = DateTimeOffset.UtcNow.AddSeconds(60);
            _message.Text = "Blocco sospeso per 60 secondi. "
                + "Mantieni questa finestra aperta: ripristino automatico alla scadenza.";
            RefreshState();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Ads Kill — errore",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void TickTimer()
    {
        if (_rewardDeadline is null)
        {
            RefreshState();
            return;
        }

        var remaining = _rewardDeadline.Value - DateTimeOffset.UtcNow;
        if (remaining > TimeSpan.Zero)
        {
            _message.Text = "Ricompensa: " + Math.Ceiling(remaining.TotalSeconds)
                + " secondi rimasti. Lascia Ads Kill aperto.";
            RefreshState();
            return;
        }

        try
        {
            HostsStore.SetProtected(true);
            _rewardDeadline = null;
            _message.Text = "Protezione riattivata automaticamente.";
        }
        catch (Exception ex)
        {
            _rewardDeadline = null;
            _message.Text = "Riattivazione non riuscita: premi Attiva blocco.";
            MessageBox.Show(this, ex.Message, "Riattivazione richiesta",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        RefreshState();
    }

    private void RefreshState()
    {
        try
        {
            bool enabled = HostsStore.IsProtected();
            _status.Text = enabled ? "● Protezione attiva" : "○ Protezione disattivata";
            _status.ForeColor = enabled ? Color.DarkGreen : Color.DarkRed;
            _rules.Text = enabled
                ? HostsSections.Domains.Length + " domini pubblicitari nel file HOSTS"
                : "Regole Ads Kill non presenti nel file HOSTS";
            _enable.Enabled = !enabled && _rewardDeadline is null;
            _disable.Enabled = enabled || _rewardDeadline is not null;
            _reward.Enabled = enabled && _rewardDeadline is null;
        }
        catch (Exception ex)
        {
            _status.Text = "Impossibile leggere il file HOSTS";
            _rules.Text = ex.Message;
            _enable.Enabled = false;
            _disable.Enabled = false;
            _reward.Enabled = false;
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        _timer.Stop();
        if (_rewardDeadline is not null)
        {
            try
            {
                HostsStore.SetProtected(true);
                _rewardDeadline = null;
            }
            catch (Exception ex)
            {
                e.Cancel = true;
                _timer.Start();
                MessageBox.Show(this,
                    "Non posso chiudere mentre il blocco è sospeso e il ripristino fallisce: "
                    + ex.Message + "\nPremi Attiva blocco oppure Disattiva blocco per scegliere.",
                    "Ads Kill — ripristino", MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
            }
        }
        base.OnFormClosing(e);
    }
}
