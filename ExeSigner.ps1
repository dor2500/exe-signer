# ExeSigner.ps1 - modern WPF desktop app: drop an EXE, inspect it, sign it with an auto-created certificate.
param(
    [string]$InitialFile,
    [string]$Screenshot,          # optional: render the window to this PNG and exit (used for README images)
    [switch]$ShowLog,
    [string]$Publisher,           # optional: override the saved publisher name
    [switch]$AutoSign,            # optional: sign InitialFile right away (used with -Screenshot for demos/tests)
    [ValidateSet('', 'auto', 'existing')][string]$Mode,   # optional: certificate source
    [string]$PfxPath,             # optional: preload a PFX/CER/CRT (password from $env:EXESIGNER_PFX_PASSWORD)
    [string]$CertKeyPath          # optional: PEM private key for a .cer/.crt given in -PfxPath
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$CorePath = Join-Path $PSScriptRoot 'SignerCore.ps1'
. $CorePath

# --- settings ---------------------------------------------------------------
$settingsPath = Join-Path $env:APPDATA 'ExeSigner\settings.json'
$settings = @{ Publisher = $env:USERNAME; Timestamp = $true; Mode = 'auto'; Thumbprint = $null }
try {
    if (Test-Path $settingsPath) {
        $s = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($s.Publisher) { $settings.Publisher = $s.Publisher }
        if ($null -ne $s.Timestamp) { $settings.Timestamp = [bool]$s.Timestamp }
        if ($s.Mode -in 'auto', 'existing') { $settings.Mode = $s.Mode }
        if ($s.Thumbprint) { $settings.Thumbprint = $s.Thumbprint }
    }
} catch { }
if ($Publisher) { $settings.Publisher = $Publisher }
if ($Mode) { $settings.Mode = $Mode }

# --- layout -----------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Exe Signer" Width="1140" Height="860" MinWidth="980" MinHeight="680"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        Background="#0E1120" FlowDirection="RightToLeft" AllowDrop="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" UseLayoutRounding="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="52" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>
    <SolidColorBrush x:Key="Bg" Color="#0E1120"/>
    <SolidColorBrush x:Key="Surface" Color="#161A2E"/>
    <SolidColorBrush x:Key="Surface2" Color="#1E2342"/>
    <SolidColorBrush x:Key="Stroke" Color="#272D4F"/>
    <SolidColorBrush x:Key="Fg" Color="#ECEEFB"/>
    <SolidColorBrush x:Key="Muted" Color="#8A90B4"/>
    <LinearGradientBrush x:Key="Accent" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#5B8CFF" Offset="0"/>
      <GradientStop Color="#9B5CFF" Offset="1"/>
    </LinearGradientBrush>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Surface}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="16"/>
      <Setter Property="Padding" Value="20"/>
    </Style>

    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="{StaticResource Surface2}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,10"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="11" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.86"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.38"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,15"/>
    </Style>

    <Style x:Key="BtnChrome" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#262C4E"/>
                <Setter Property="Foreground" Value="#ECEEFB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnClose" TargetType="Button" BasedOn="{StaticResource BtnChrome}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#E5484D"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <ContentPresenter VerticalAlignment="Center"/>
              <Border x:Name="track" Grid.Column="1" Width="42" Height="24" CornerRadius="12" Background="#2A3052"
                      Margin="14,0,0,0" VerticalAlignment="Center">
                <Ellipse x:Name="knob" Width="18" Height="18" Fill="#B9BEDD" HorizontalAlignment="Left" Margin="3,0"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="knob" Property="Fill" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="{StaticResource Bg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Fg}"/>
      <Setter Property="SelectionBrush" Value="#5B8CFF"/>
      <Setter Property="Padding" Value="10,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#5B8CFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PwInput" TargetType="PasswordBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="{StaticResource Bg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Fg}"/>
      <Setter Property="Padding" Value="10,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#5B8CFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="8" Padding="8,8" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#ECEEFB"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#272E58"/>
                <Setter Property="Foreground" Value="#ECEEFB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CertItem" TargetType="ListBoxItem">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="b" CornerRadius="10" Padding="12,9" Margin="0,0,0,6" Background="{StaticResource Bg}"
                    BorderBrush="{StaticResource Stroke}" BorderThickness="1">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#39416E"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="#5B8CFF"/>
                <Setter TargetName="b" Property="Background" Value="#1A2045"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Val" TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="SelectionBrush" Value="#5B8CFF"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <ScrollViewer x:Name="PART_ContentHost" VerticalScrollBarVisibility="Disabled"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border CornerRadius="4" Background="#343B66"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border Name="Root" Background="{StaticResource Bg}">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="56"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- title bar -->
      <Grid Margin="22,0,10,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="32" Height="32" CornerRadius="10" Background="{StaticResource Accent}">
            <TextBlock Style="{StaticResource Icon}" Text="&#xEA18;" Foreground="White" FontSize="16"/>
          </Border>
          <TextBlock Text="Exe Signer" Foreground="{StaticResource Fg}" FontSize="16" FontWeight="SemiBold" Margin="12,0,0,0" VerticalAlignment="Center"/>
          <Border Background="#1E2342" CornerRadius="6" Padding="8,2" Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="בדיקה וחתימה דיגיטלית לקבצי הפעלה" Foreground="{StaticResource Muted}" FontSize="12.5"/>
          </Border>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" WindowChrome.IsHitTestVisibleInChrome="True">
          <Button Name="BtnMin" Style="{StaticResource BtnChrome}" Content="&#xE921;"/>
          <Button Name="BtnMax" Style="{StaticResource BtnChrome}" Content="&#xE922;"/>
          <Button Name="BtnClose" Style="{StaticResource BtnClose}" Content="&#xE8BB;"/>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1" Margin="22,4,22,22">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="20"/>
          <ColumnDefinition Width="370"/>
        </Grid.ColumnDefinitions>

        <!-- main column -->
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <Border Name="DropZone" CornerRadius="16" Background="{StaticResource Surface}" Height="160" Cursor="Hand" AllowDrop="True">
            <Grid>
              <Rectangle Name="DropDash" RadiusX="16" RadiusY="16" Stroke="#39416E" StrokeThickness="1.6" StrokeDashArray="5 4"/>
              <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                <Border Width="56" Height="56" CornerRadius="28" Background="#232A52" HorizontalAlignment="Center">
                  <TextBlock Name="DropIcon" Style="{StaticResource Icon}" Text="&#xE898;" FontSize="22" Foreground="#8FA8FF"/>
                </Border>
                <TextBlock Name="DropTitle" Text="גרור לכאן קובץ EXE, DLL או MSI" Foreground="{StaticResource Fg}" FontSize="18" FontWeight="SemiBold" Margin="0,14,0,3" HorizontalAlignment="Center"/>
                <TextBlock Text="או לחץ כדי לבחור קובץ מהמחשב" Foreground="{StaticResource Muted}" FontSize="13" HorizontalAlignment="Center"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,18,0,0" Padding="0">
            <Grid>
              <StackPanel Name="EmptyState" VerticalAlignment="Center" HorizontalAlignment="Center">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE8A5;" FontSize="40" Foreground="#39416E"/>
                <TextBlock Text="עדיין לא נבחר קובץ" Foreground="{StaticResource Fg}" FontSize="16" FontWeight="SemiBold" Margin="0,14,0,4" HorizontalAlignment="Center"/>
                <TextBlock Text="דוח הבדיקה יופיע כאן: מבנה הקובץ, גרסה, Hash וחתימה קיימת" Foreground="{StaticResource Muted}" FontSize="13" HorizontalAlignment="Center"/>
              </StackPanel>

              <Grid Name="ResultPanel" Visibility="Collapsed">
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border Padding="22,20" BorderBrush="{StaticResource Stroke}" BorderThickness="0,0,0,1">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Border Name="StatusIconBg" Width="52" Height="52" CornerRadius="14">
                      <TextBlock Name="StatusIcon" Style="{StaticResource Icon}" FontSize="22"/>
                    </Border>
                    <StackPanel Grid.Column="1" Margin="16,0,16,0" VerticalAlignment="Center">
                      <TextBlock Name="FileName" Foreground="{StaticResource Fg}" FontSize="19" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                      <TextBlock Name="FilePath" Foreground="{StaticResource Muted}" FontSize="12" Margin="0,3,0,0" TextTrimming="CharacterEllipsis" FlowDirection="LeftToRight" TextAlignment="Right"/>
                    </StackPanel>
                    <Border Grid.Column="2" Name="StatusChip" CornerRadius="15" Padding="14,6" VerticalAlignment="Center">
                      <TextBlock Name="StatusText" FontSize="13" FontWeight="SemiBold"/>
                    </Border>
                  </Grid>
                </Border>
                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                  <StackPanel Name="Rows" Margin="22,6,22,14"/>
                </ScrollViewer>
              </Grid>

              <Border Name="LogPanel" Visibility="Collapsed" VerticalAlignment="Bottom" Height="190" Margin="12"
                      Background="#0B0E1A" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="12" Padding="12,10">
                <TextBox Name="LogBox" Style="{StaticResource Val}" FlowDirection="LeftToRight" FontFamily="Cascadia Mono, Consolas"
                         FontSize="12" Foreground="#AEB4D8" TextWrapping="NoWrap">
                  <TextBox.Template>
                    <ControlTemplate TargetType="TextBox">
                      <ScrollViewer x:Name="PART_ContentHost" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
                    </ControlTemplate>
                  </TextBox.Template>
                </TextBox>
              </Border>
            </Grid>
          </Border>
        </Grid>

        <!-- side column -->
        <Grid Grid.Column="2">
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Border Width="30" Height="30" CornerRadius="9" Background="#232A52">
                  <TextBlock Style="{StaticResource Icon}" Text="&#xEB95;" Foreground="#8FA8FF" FontSize="15"/>
                </Border>
                <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
                  <TextBlock Text="תעודת חתימה" Foreground="{StaticResource Fg}" FontSize="15" FontWeight="SemiBold"/>
                  <TextBlock Name="CertSubtitle" Text="נוצרת אוטומטית בחתימה הראשונה" Foreground="{StaticResource Muted}" FontSize="12"/>
                </StackPanel>
              </StackPanel>

              <Border Background="{StaticResource Bg}" CornerRadius="11" Padding="4" Margin="0,16,0,0">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <RadioButton Name="ModeAuto" GroupName="CertMode" Style="{StaticResource Seg}" Content="תעודה אוטומטית" IsChecked="True"/>
                  <RadioButton Name="ModeExisting" Grid.Column="1" GroupName="CertMode" Style="{StaticResource Seg}" Content="תעודה קיימת"/>
                </Grid>
              </Border>

              <StackPanel Name="AutoPanel">
                <TextBlock Text="שם המפרסם" Foreground="{StaticResource Muted}" FontSize="12.5" Margin="0,16,0,6"/>
                <TextBox Name="TxtPublisher" Style="{StaticResource Input}"/>
              </StackPanel>

              <StackPanel Name="ExistingPanel" Visibility="Collapsed">
                <TextBlock Text="תעודות חתימת קוד במחשב" Foreground="{StaticResource Muted}" FontSize="12.5" Margin="0,16,0,6"/>
                <ListBox Name="CertList" MaxHeight="150" Background="Transparent" BorderThickness="0"
                         ItemContainerStyle="{StaticResource CertItem}"
                         ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
                <TextBlock Name="CertListEmpty" Visibility="Collapsed" Foreground="{StaticResource Muted}" FontSize="12.5" TextWrapping="Wrap"
                           Text="לא נמצאו במחשב תעודות לחתימת קוד. אפשר לטעון קובץ PFX."/>
                <TextBlock Text="או טעינה מקובץ PFX / P12 / CER / CRT" Foreground="{StaticResource Muted}" FontSize="12.5" Margin="0,12,0,6"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <PasswordBox Name="PfxPassword" Style="{StaticResource PwInput}" ToolTip="סיסמת קובץ ה-PFX או של המפתח הפרטי (אם יש)"/>
                  <Button Name="BtnPfx" Grid.Column="2" Style="{StaticResource Btn}">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE8E5;" FontSize="13" Margin="0,0,8,0"/>
                      <TextBlock Text="בחר קובץ…"/>
                    </StackPanel>
                  </Button>
                </Grid>
                <TextBlock Text="קודם מקלידים סיסמה (אם יש), ואז בוחרים את הקובץ. ל-CER/CRT צריך גם את המפתח הפרטי: מהמחשב או מקובץ ‎.key." Foreground="{StaticResource Muted}" FontSize="11.5" Margin="0,6,0,0" TextWrapping="Wrap"/>
              </StackPanel>

              <Border Margin="0,12,0,0" CornerRadius="11" Background="{StaticResource Bg}" Padding="14,11">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <Ellipse Name="CertDot" Width="8" Height="8" VerticalAlignment="Center"/>
                    <TextBlock Name="CertTitle" Foreground="{StaticResource Fg}" FontSize="13" FontWeight="SemiBold" Margin="9,0,0,0"/>
                  </StackPanel>
                  <TextBlock Name="CertDetail" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="17,4,0,0"/>
                </StackPanel>
              </Border>
              <Grid Margin="0,12,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="10"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button Name="BtnTrust" Style="{StaticResource Btn}">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Style="{StaticResource Icon}" Text="&#xE72E;" FontSize="13" Margin="0,0,8,0"/>
                    <TextBlock Text="סמוך במחשב הזה"/>
                  </StackPanel>
                </Button>
                <Button Name="BtnExport" Grid.Column="2" Style="{StaticResource Btn}">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Style="{StaticResource Icon}" Text="&#xE896;" FontSize="13" Margin="0,0,8,0"/>
                    <TextBlock Text="ייצוא ‎.cer"/>
                  </StackPanel>
                </Button>
              </Grid>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}" Margin="0,18,0,0" VerticalAlignment="Top">
            <StackPanel>
              <TextBlock Text="אפשרויות" Foreground="{StaticResource Fg}" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,14"/>
              <CheckBox Name="ChkTs" Style="{StaticResource Switch}">
                <StackPanel>
                  <TextBlock Text="חותמת זמן" Foreground="{StaticResource Fg}"/>
                  <TextBlock Text="החתימה נשארת תקפה גם אחרי שהתעודה פגה" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap"/>
                </StackPanel>
              </CheckBox>
              <Border Height="1" Background="{StaticResource Stroke}" Margin="0,14"/>
              <CheckBox Name="ChkOverwrite" Style="{StaticResource Switch}">
                <StackPanel>
                  <TextBlock Text="חתום על הקובץ המקורי" Foreground="{StaticResource Fg}"/>
                  <TextBlock Text="כבוי: נוצר עותק חדש עם הסיומת ‎-signed" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap"/>
                </StackPanel>
              </CheckBox>
            </StackPanel>
          </Border>
          </StackPanel>
          </ScrollViewer>

          <StackPanel Grid.Row="1" Margin="0,18,0,0">
            <Border Name="Banner" Visibility="Collapsed" CornerRadius="12" Padding="14,11" Margin="0,0,0,12" BorderThickness="1">
              <StackPanel Orientation="Horizontal">
                <TextBlock Name="BannerIcon" Style="{StaticResource Icon}" FontSize="15" VerticalAlignment="Top" Margin="0,2,10,0"/>
                <TextBlock Name="BannerText" TextWrapping="Wrap" FontSize="13" MaxWidth="300"/>
              </StackPanel>
            </Border>
            <Button Name="BtnSign" Style="{StaticResource BtnPrimary}" IsEnabled="False">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE70F;" FontSize="16" Margin="0,0,10,0"/>
                <TextBlock Name="SignText" Text="חתום על הקובץ"/>
              </StackPanel>
            </Button>
            <ProgressBar Name="Progress" IsIndeterminate="True" Height="3" Margin="6,8,6,0" Visibility="Hidden"
                         Foreground="#8C7CFF" Background="Transparent" BorderThickness="0"/>
            <Grid Margin="0,6,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Button Name="BtnOpen" Style="{StaticResource Btn}" IsEnabled="False">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Style="{StaticResource Icon}" Text="&#xE838;" FontSize="13" Margin="0,0,8,0"/>
                  <TextBlock Text="פתח תיקייה"/>
                </StackPanel>
              </Button>
              <Button Name="BtnLog" Grid.Column="2" Style="{StaticResource Btn}">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Style="{StaticResource Icon}" Text="&#xE9F9;" FontSize="13" Margin="0,0,8,0"/>
                  <TextBlock Text="יומן פעולות"/>
                </StackPanel>
              </Button>
            </Grid>
          </StackPanel>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in $xaml.SelectNodes('//*[@Name]')) { $ui[$n.GetAttribute('Name')] = $win.FindName($n.GetAttribute('Name')) }

# --- helpers ----------------------------------------------------------------
$bc = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$hex) { $bc.ConvertFromString($hex) }
$Pal = @{ ok = '#3DDC97'; warn = '#FFB547'; bad = '#FF5C7A'; info = '#8FA8FF'; muted = '#8A90B4' }
function Get-Tint([string]$hex, [string]$alpha = '24') { '#' + $alpha + $hex.TrimStart('#') }

$script:CurrentFile = $null
$script:LastOutput = $null
$script:LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:SignJob = $null

function Write-Log([string]$m) {
    $ui.LogBox.AppendText(("[{0:HH:mm:ss}] {1}`r`n" -f (Get-Date), $m))
    $ui.LogBox.ScrollToEnd()
}

function Save-Settings {
    try {
        $dir = Split-Path $settingsPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
        if ($Screenshot) { return }   # demo/automation runs never touch the user's settings
        $mode = if ($ui.ModeExisting.IsChecked) { 'existing' } else { 'auto' }
        $thumb = $settings.Thumbprint
        $sel = $ui.CertList.SelectedItem
        if ($sel -and -not ($script:PfxCert -and $sel.Tag.Thumbprint -eq $script:PfxCert.Thumbprint)) { $thumb = $sel.Tag.Thumbprint }
        $settings.Thumbprint = $thumb
        @{ Publisher = $ui.TxtPublisher.Text; Timestamp = [bool]$ui.ChkTs.IsChecked; Mode = $mode; Thumbprint = $thumb } |
            ConvertTo-Json | Set-Content $settingsPath -Encoding UTF8
    } catch { }
}

function Show-Banner([string]$kind, [string]$text) {
    if (-not $kind) { $ui.Banner.Visibility = 'Collapsed'; return }
    $col = $Pal[$kind]
    $ui.Banner.Background = Get-Brush (Get-Tint $col '1F')
    $ui.Banner.BorderBrush = Get-Brush (Get-Tint $col '55')
    $ui.BannerIcon.Foreground = Get-Brush $col
    $ui.BannerIcon.Text = switch ($kind) { 'ok' { [char]0xE73E } 'bad' { [char]0xE783 } default { [char]0xE7BA } }
    $ui.BannerText.Foreground = Get-Brush '#ECEEFB'
    $ui.BannerText.Text = $text
    $ui.Banner.Visibility = 'Visible'
}

function Add-Row([string]$key, [string]$value, [string]$level = 'info', [switch]$Ltr) {
    $g = New-Object Windows.Controls.Grid
    foreach ($w in '22', '160', '*') {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object Windows.GridLengthConverter).ConvertFromString($w)
        $g.ColumnDefinitions.Add($cd)
    }
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 7; $dot.Height = 7; $dot.VerticalAlignment = 'Top'; $dot.Margin = '0,7,0,0'; $dot.HorizontalAlignment = 'Left'
    $dot.Fill = Get-Brush $Pal[$level]
    $k = New-Object Windows.Controls.TextBlock
    $k.Text = $key; $k.Foreground = Get-Brush $Pal.muted; $k.FontSize = 13; $k.Margin = '0,1,0,0'
    [Windows.Controls.Grid]::SetColumn($k, 1)
    $v = New-Object Windows.Controls.TextBox
    $v.Style = $win.FindResource('Val')
    $v.Text = $value
    $v.FontSize = 13.5
    if ($level -eq 'warn' -or $level -eq 'bad') { $v.Foreground = Get-Brush $Pal[$level] }
    if ($Ltr) {
        $v.FlowDirection = 'LeftToRight'; $v.TextAlignment = 'Right'
        $v.FontFamily = New-Object Windows.Media.FontFamily 'Cascadia Mono, Consolas'; $v.FontSize = 12
    }
    [Windows.Controls.Grid]::SetColumn($v, 2)
    [void]$g.Children.Add($dot); [void]$g.Children.Add($k); [void]$g.Children.Add($v)
    $b = New-Object Windows.Controls.Border
    $b.Padding = '0,11'; $b.BorderBrush = Get-Brush '#22284A'; $b.BorderThickness = '0,0,0,1'; $b.Child = $g
    [void]$ui.Rows.Children.Add($b)
}

function Set-Status([string]$level, [char]$glyph, [string]$text) {
    $col = $Pal[$level]
    $ui.StatusIconBg.Background = Get-Brush (Get-Tint $col '22')
    $ui.StatusIcon.Foreground = Get-Brush $col
    $ui.StatusIcon.Text = $glyph
    $ui.StatusChip.Background = Get-Brush (Get-Tint $col '22')
    $ui.StatusText.Foreground = Get-Brush $col
    $ui.StatusText.Text = $text
}

function Show-Report([string]$path) {
    $ui.Rows.Children.Clear()
    $ui.EmptyState.Visibility = 'Collapsed'
    $ui.ResultPanel.Visibility = 'Visible'
    $ui.FileName.Text = [IO.Path]::GetFileName($path)
    $ui.FilePath.Text = $path
    try { $r = Get-ExeReport $path } catch {
        Set-Status 'bad' ([char]0xE783) 'שגיאה'
        Add-Row 'שגיאה' $_.Exception.Message 'bad'
        return $null
    }

    $signedByUs = $false
    switch ($r.SigStatus) {
        'Valid' {
            if ($r.SigType -eq 'Catalog') { Set-Status 'ok' ([char]0xE73E) 'חתום (קטלוג Windows)' }
            else { Set-Status 'ok' ([char]0xE73E) 'חתום ותקף' }
        }
        'NotSigned' { Set-Status 'warn' ([char]0xE7BA) 'לא חתום' }
        'UnknownError' {
            if ($r.Signer) { Set-Status 'warn' ([char]0xEA18) 'חתום · תעודה לא מאושרת' } else { Set-Status 'bad' ([char]0xE783) 'שגיאת חתימה' }
        }
        'HashMismatch' { Set-Status 'bad' ([char]0xE783) 'חתימה שבורה' }
        default { Set-Status 'bad' ([char]0xE783) $r.SigStatus }
    }
    if (-not $r.Pe.IsPe -and $r.Path -notmatch '\.(msi|ps1|cab|cat|msix|appx)$') { Set-Status 'bad' ([char]0xE783) 'לא קובץ הפעלה' }

    Add-Row 'גודל' ('{0:N2} MB  ({1:N0} bytes)' -f ($r.SizeBytes / 1MB), $r.SizeBytes) -Ltr
    if ($r.Pe.IsPe) {
        $kind = if ($r.Pe.IsDll) { 'DLL' } else { 'EXE' }
        $net = if ($r.Pe.IsDotNet) { '  ·  .NET' } else { '' }
        Add-Row 'מבנה הקובץ' ('{0} תקין  ·  {1}  ·  {2}  ·  {3}{4}' -f $kind, $r.Pe.Format, $r.Pe.Machine, $r.Pe.Subsystem, $net) 'ok'
        Add-Row 'תאריך קומפילציה' ('{0:dd/MM/yyyy HH:mm} UTC' -f $r.Pe.LinkTime)
        if ($r.Pe.HasSignatureBlock -and $r.Pe.SignatureEndsAtEof -eq $false) {
            Add-Row 'אזהרה' 'יש נתונים אחרי בלוק החתימה (overlay). חתימה מחדש עלולה לשבור את הקובץ.' 'warn'
        }
    } elseif ($r.Path -match '\.(msi|ps1|cab|cat|msix|appx)$') {
        Add-Row 'מבנה הקובץ' 'לא PE, אבל זה סוג קובץ שאפשר לחתום עליו'
    } else {
        Add-Row 'מבנה הקובץ' ('לא תקין: ' + $r.Pe.Error) 'bad'
    }
    if ($r.ProductName) { Add-Row 'מוצר' $r.ProductName }
    if ($r.CompanyName) { Add-Row 'חברה' $r.CompanyName }
    if ($r.FileVersion) { Add-Row 'גרסה' $r.FileVersion -Ltr }
    if ($r.Description) { Add-Row 'תיאור' $r.Description }
    Add-Row 'SHA-256' $r.Sha256 -Ltr

    switch ($r.SigStatus) {
        'Valid'        { Add-Row 'חתימה דיגיטלית' 'חתום ותקף' 'ok' }
        'NotSigned'    { Add-Row 'חתימה דיגיטלית' 'הקובץ לא חתום' 'warn' }
        'UnknownError' {
            if ($r.Signer) { Add-Row 'חתימה דיגיטלית' 'חתום, אבל התעודה לא מאושרת במחשב הזה (תעודה עצמית)' 'warn' }
            else { Add-Row 'חתימה דיגיטלית' $r.SigMessage 'bad' }
        }
        'HashMismatch' { Add-Row 'חתימה דיגיטלית' 'הקובץ שונה אחרי שנחתם, החתימה שבורה' 'bad' }
        default        { Add-Row 'חתימה דיגיטלית' ($r.SigStatus + ': ' + $r.SigMessage) 'bad' }
    }
    if ($r.Signer) {
        Add-Row 'חותם' $r.Signer -Ltr
        if ($r.SigType -eq 'Catalog') { Add-Row 'סוג חתימה' 'קטלוג של Windows (לא מוטמעת בקובץ)' }
        elseif ($r.SigType) { Add-Row 'סוג חתימה' 'Authenticode, מוטמעת בקובץ' }
        if ($r.Timestamped) { Add-Row 'חותמת זמן' 'יש' 'ok' } else { Add-Row 'חותמת זמן' 'אין' 'warn' }
    }
    if ($r.FromInternet) { Add-Row 'מקור' 'הקובץ הורד מהאינטרנט (Mark of the Web)' 'warn' }
    return $r
}

function Test-ExistingMode { return [bool]$ui.ModeExisting.IsChecked }

function Get-SelectedCert {
    if (Test-ExistingMode) {
        if ($ui.CertList.SelectedItem) { return $ui.CertList.SelectedItem.Tag }
        return $null
    }
    return (Get-SignerCert $ui.TxtPublisher.Text)
}

function Set-TrustButton([bool]$visible) {
    # Trust is only offered for self-signed certificates; Export takes the full row otherwise.
    $ui.BtnTrust.Visibility = if ($visible) { 'Visible' } else { 'Collapsed' }
    if ($visible) { [Windows.Controls.Grid]::SetColumn($ui.BtnExport, 2); [Windows.Controls.Grid]::SetColumnSpan($ui.BtnExport, 1) }
    else { [Windows.Controls.Grid]::SetColumn($ui.BtnExport, 0); [Windows.Controls.Grid]::SetColumnSpan($ui.BtnExport, 3) }
}

function Update-SignEnabled {
    $ok = [bool]$script:CurrentFile -and -not $script:SignJob
    if ($ok -and (Test-ExistingMode)) { $ok = [bool]$ui.CertList.SelectedItem }
    $ui.BtnSign.IsEnabled = $ok
}

function New-CertListItem($cert, [bool]$fromPfx) {
    $sp = New-Object Windows.Controls.StackPanel
    $top = New-Object Windows.Controls.StackPanel
    $top.Orientation = 'Horizontal'
    $name = New-Object Windows.Controls.TextBlock
    $name.Text = Get-CertDisplayName $cert
    $name.Foreground = Get-Brush '#ECEEFB'; $name.FontSize = 13; $name.FontWeight = 'SemiBold'
    $name.TextTrimming = 'CharacterEllipsis'; $name.MaxWidth = 230
    [void]$top.Children.Add($name)
    if ($fromPfx) {
        $tag = New-Object Windows.Controls.Border
        $tag.Background = Get-Brush '#2A2F5C'; $tag.CornerRadius = '5'; $tag.Padding = '6,1'; $tag.Margin = '8,0,0,0'
        $tt = New-Object Windows.Controls.TextBlock
        $tt.Text = $(if ($script:FileTag) { $script:FileTag } else { 'PFX' });$tt.FontSize = 10.5; $tt.Foreground = Get-Brush '#AFC0FF'
        $tag.Child = $tt
        [void]$top.Children.Add($tag)
    }
    $det = New-Object Windows.Controls.TextBlock
    $det.Text = ('{0}  ·  עד {1:dd/MM/yyyy}' -f (Get-CertIssuerName $cert), $cert.NotAfter)
    $det.Foreground = Get-Brush $Pal.muted; $det.FontSize = 11.5; $det.Margin = '0,2,0,0'
    $det.TextTrimming = 'CharacterEllipsis'
    [void]$sp.Children.Add($top); [void]$sp.Children.Add($det)
    $item = New-Object Windows.Controls.ListBoxItem
    $item.Content = $sp
    $item.Tag = $cert
    $item.Style = $win.FindResource('CertItem')
    return $item
}

function Update-CertList([string]$selectThumb) {
    $script:FillingList = $true
    try {
        $ui.CertList.Items.Clear()
        $all = @()
        if ($script:PfxCert) { $all += , @($script:PfxCert, $true) }
        $store = if ($env:EXESIGNER_DEMO_HIDE_STORE) { @() } else { @(Get-StoreSigningCerts) }
        foreach ($c in $store) {
            if ($script:PfxCert -and $c.Thumbprint -eq $script:PfxCert.Thumbprint) { continue }
            $all += , @($c, $false)
        }
        foreach ($pair in $all) { [void]$ui.CertList.Items.Add((New-CertListItem $pair[0] $pair[1])) }
        $ui.CertListEmpty.Visibility = if ($all.Count) { 'Collapsed' } else { 'Visible' }
        $ui.CertList.Visibility = if ($all.Count) { 'Visible' } else { 'Collapsed' }
        $pick = $null
        if ($selectThumb) { $pick = $ui.CertList.Items | Where-Object { $_.Tag.Thumbprint -eq $selectThumb } | Select-Object -First 1 }
        if (-not $pick -and $ui.CertList.Items.Count) { $pick = $ui.CertList.Items[0] }
        $ui.CertList.SelectedItem = $pick
    } finally { $script:FillingList = $false }
}

function Update-Cert {
    if (Test-ExistingMode) {
        $ui.CertSubtitle.Text = 'מהמחשב, מטוקן USB או מקובץ PFX'
        $c = Get-SelectedCert
        if (-not $c) {
            $ui.CertDot.Fill = Get-Brush $Pal.muted
            $ui.CertTitle.Text = 'לא נבחרה תעודה'
            $ui.CertDetail.Text = 'בחר תעודה מהרשימה או טען קובץ PFX.'
            Set-TrustButton $false; $ui.BtnExport.IsEnabled = $false
            Update-SignEnabled
            return
        }
        $selfSigned = ($c.Issuer -eq $c.Subject)
        if (Test-CertChainTrusted $c) {
            $ui.CertDot.Fill = Get-Brush $Pal.ok
            $ui.CertTitle.Text = if ($selfSigned) { 'מאושרת במחשב הזה' } else { 'מהימנה · הונפקה ע"י ' + (Get-CertIssuerName $c) }
        } else {
            $ui.CertDot.Fill = Get-Brush $Pal.warn
            $ui.CertTitle.Text = if ($selfSigned) { 'תעודה עצמית, לא מאושרת במחשב הזה' } else { 'השרשרת לא מאומתת במחשב הזה' }
        }
        $ui.CertDetail.Text = ('{0}  ·  בתוקף עד {1:dd/MM/yyyy}  ·  {2}' -f (Get-CertDisplayName $c), $c.NotAfter, $c.Thumbprint.Substring(0, 12))
        Set-TrustButton ($selfSigned -and -not (Test-CertTrustedLocally $c))
        $ui.BtnTrust.IsEnabled = $true
        $ui.BtnExport.IsEnabled = $true
        Update-SignEnabled
        return
    }

    $ui.CertSubtitle.Text = 'נוצרת אוטומטית בחתימה הראשונה'
    Set-TrustButton $true
    $c = Get-SignerCert $ui.TxtPublisher.Text
    if (-not $c) {
        $ui.CertDot.Fill = Get-Brush $Pal.muted
        $ui.CertTitle.Text = 'עדיין אין תעודה'
        $ui.CertDetail.Text = 'היא תיווצר אוטומטית כשתחתום על הקובץ הראשון.'
        $ui.BtnTrust.IsEnabled = $false; $ui.BtnExport.IsEnabled = $false
        Update-SignEnabled
        return
    }
    $trusted = Test-CertTrustedLocally $c
    if ($trusted) { $ui.CertDot.Fill = Get-Brush $Pal.ok; $ui.CertTitle.Text = 'מאושרת במחשב הזה' }
    else { $ui.CertDot.Fill = Get-Brush $Pal.warn; $ui.CertTitle.Text = 'קיימת, עדיין לא מאושרת במחשב הזה' }
    $ui.CertDetail.Text = ('בתוקף עד {0:dd/MM/yyyy}  ·  {1}' -f $c.NotAfter, $c.Thumbprint.Substring(0, 12))
    $ui.BtnTrust.IsEnabled = -not $trusted
    $ui.BtnExport.IsEnabled = $true
    Update-SignEnabled
}

function Set-Mode([string]$mode) {
    $existing = ($mode -eq 'existing')
    $ui.ModeExisting.IsChecked = $existing
    $ui.ModeAuto.IsChecked = -not $existing
    $ui.AutoPanel.Visibility = if ($existing) { 'Collapsed' } else { 'Visible' }
    $ui.ExistingPanel.Visibility = if ($existing) { 'Visible' } else { 'Collapsed' }
    if ($existing -and $ui.CertList.Items.Count -eq 0) { Update-CertList $settings.Thumbprint }
    Update-Cert
}

function Import-CertFromUi([string]$path, [System.Security.SecureString]$password, [string]$keyPath, [switch]$NoKeyPrompt) {
    $isPfx = [IO.Path]::GetExtension($path) -match '^\.(pfx|p12)$'
    try {
        $cert = Import-CertFileForSigning -Path $path -Password $password -KeyPath $keyPath -Log { param($m) Write-Log $m }
        $script:PfxCert = $cert
        $script:FileTag = [IO.Path]::GetExtension($path).TrimStart('.').ToUpperInvariant()
        Update-CertList $cert.Thumbprint
        Update-Cert
        Write-Log ("Loaded certificate: " + $cert.Subject + " (" + $cert.Thumbprint + ")")
        Show-Banner 'ok' ('התעודה נטענה: ' + (Get-CertDisplayName $cert))
    } catch {
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        Write-Log ("CERT ERROR: " + $ex.Message)
        if ($ex.Data['NeedsKey']) {
            if (-not $NoKeyPrompt) {
                Show-Banner 'warn' 'קובץ CER/CRT מכיל רק את החלק הציבורי של התעודה. בחר עכשיו את קובץ המפתח הפרטי (.key / .pem).'
                $dlg = New-Object Microsoft.Win32.OpenFileDialog
                $dlg.Title = 'בחר את המפתח הפרטי של התעודה'
                $dlg.Filter = 'מפתח פרטי (*.key;*.pem)|*.key;*.pem|כל הקבצים (*.*)|*.*'
                $dlg.InitialDirectory = Split-Path $path
                if ($dlg.ShowDialog($win)) { Import-CertFromUi $path $password $dlg.FileName -NoKeyPrompt; return }
            }
            Show-Banner 'bad' ('לא נמצא המפתח הפרטי של התעודה, ובלעדיו אי אפשר לחתום. אפשר: להתקין אותה עם המפתח (למשל מטוקן או מ-PFX), ' +
                'לבחור קובץ ‎.key מתאים, או לקבל מהספק קובץ PFX.')
        } elseif ($isPfx -and $ex -is [System.Security.Cryptography.CryptographicException]) {
            Show-Banner 'bad' 'לא הצלחתי לפתוח את הקובץ. כנראה שהסיסמה שגויה: הקלד אותה ובחר את הקובץ שוב.'
        } elseif ($ex.Message -match 'encrypted') {
            Show-Banner 'bad' 'המפתח הפרטי מוצפן: הקלד את הסיסמה שלו ובחר את הקובץ שוב.'
        } elseif ($ex.Message -match 'does not belong|does not match') {
            Show-Banner 'bad' 'המפתח הפרטי שבחרת לא שייך לתעודה הזו.'
        } elseif ($ex.Message -match 'not allowed to sign code') {
            Show-Banner 'bad' 'התעודה הזו לא מיועדת לחתימת קוד (חסר Code Signing).'
        } elseif ($ex.Message -match 'expired') {
            Show-Banner 'bad' ('פג התוקף של התעודה. ' + $ex.Message)
        } else {
            Show-Banner 'bad' ('טעינת התעודה נכשלה: ' + $ex.Message)
        }
    }
}

function Open-File([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    $script:CurrentFile = (Resolve-Path -LiteralPath $path).Path
    $script:LastOutput = $null
    $ui.BtnOpen.IsEnabled = $false
    Show-Banner $null
    Write-Log ("Loaded " + $script:CurrentFile)
    $r = Show-Report $script:CurrentFile
    if (-not $r) { $script:CurrentFile = $null }
    Update-SignEnabled
    if ($r -and $r.Signer -and $r.SigStatus -eq 'Valid' -and $r.SigType -ne 'Catalog') {
        Show-Banner 'warn' 'לקובץ כבר יש חתימה תקפה. חתימה חדשה תחליף אותה.'
    }
}

function Set-Busy([bool]$busy) {
    if ($busy) { $ui.BtnSign.IsEnabled = $false } else { Update-SignEnabled }
    $ui.Progress.Visibility = if ($busy) { 'Visible' } else { 'Hidden' }
    $ui.SignText.Text = if ($busy) { 'חותם על הקובץ…' } else { 'חתום על הקובץ' }
    $win.Cursor = if ($busy) { [Windows.Input.Cursors]::AppStarting } else { $null }
}

function Set-DropHover([bool]$on) {
    if ($on) { $ui.DropDash.Stroke = Get-Brush '#6C8CFF'; $ui.DropZone.Background = Get-Brush '#1A2045' }
    else { $ui.DropDash.Stroke = Get-Brush '#39416E'; $ui.DropZone.Background = Get-Brush '#161A2E' }
}

# --- signing runs in a background runspace so the window stays responsive ---
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    $m = $null
    while ($script:LogQueue.TryDequeue([ref]$m)) { Write-Log $m }
    $j = $script:SignJob
    if ($j -and $j.Handle.IsCompleted) {
        $timer.Stop()
        $script:SignJob = $null
        try {
            [void]$j.PS.EndInvoke($j.Handle)
            while ($script:LogQueue.TryDequeue([ref]$m)) { Write-Log $m }
            Write-Log ("Signed: " + $j.Out)
            $script:LastOutput = $j.Out
            $ui.BtnOpen.IsEnabled = $true
            [void](Show-Report $j.Out)
            Update-Cert
            Show-Banner 'ok' ('הקובץ נחתם בהצלחה: ' + [IO.Path]::GetFileName($j.Out))
        } catch {
            $ex = $_.Exception
            while ($ex.InnerException) { $ex = $ex.InnerException }
            Write-Log ("ERROR: " + $ex.Message)
            Show-Banner 'bad' ('החתימה נכשלה: ' + $ex.Message)
        } finally {
            $j.PS.Dispose()
            Set-Busy $false
        }
    }
})

function Start-Sign {
    if (-not $script:CurrentFile -or $script:SignJob) { return }
    $pub = $ui.TxtPublisher.Text.Trim()
    if (-not $pub) { $pub = $env:USERNAME; $ui.TxtPublisher.Text = $pub }
    $useCert = $null
    if (Test-ExistingMode) {
        $useCert = Get-SelectedCert
        if (-not $useCert) { Show-Banner 'warn' 'בחר תעודה קיימת או טען קובץ PFX.'; return }
        Write-Log ("Using existing certificate: " + $useCert.Subject + " (" + $useCert.Thumbprint + ")")
    }
    Save-Settings
    if ($ui.ChkOverwrite.IsChecked) { $out = $script:CurrentFile }
    else {
        $dir = Split-Path $script:CurrentFile
        $out = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($script:CurrentFile) + '-signed' + [IO.Path]::GetExtension($script:CurrentFile))
    }
    Show-Banner $null
    Set-Busy $true
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($core, $in, $out, $pub, $ts, $q, $existing)
        . $core
        $cert = if ($existing) { $existing } else { Get-SignerCert $pub }
        if (-not $cert) {
            $q.Enqueue("Creating a new code-signing certificate for '$pub' ...")
            $cert = New-SignerCert $pub
            $q.Enqueue("Certificate created: " + $cert.Thumbprint)
        }
        $null = Invoke-SignExe -InputPath $in -OutputPath $out -Cert $cert -UseTimestamp $ts -Log { param($msg) $q.Enqueue($msg) }
    })
    foreach ($a in @($CorePath, $script:CurrentFile, $out, $pub, [bool]$ui.ChkTs.IsChecked, $script:LogQueue, $useCert)) { [void]$ps.AddArgument($a) }
    $script:SignJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Out = $out }
    $timer.Start()
}

# --- events -----------------------------------------------------------------
$onDragOver = { param($s, $e)
    if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { $e.Effects = 'Copy'; Set-DropHover $true } else { $e.Effects = 'None' }
    $e.Handled = $true
}
$onDrop = { param($s, $e)
    Set-DropHover $false
    $files = $e.Data.GetData([Windows.DataFormats]::FileDrop)
    if ($files) { Open-File $files[0] }
    $e.Handled = $true
}
$win.Add_DragOver($onDragOver)
$win.Add_Drop($onDrop)
$win.Add_DragLeave({ Set-DropHover $false })

$ui.DropZone.Add_MouseEnter({ if (-not $script:SignJob) { Set-DropHover $true } })
$ui.DropZone.Add_MouseLeave({ Set-DropHover $false })
$ui.DropZone.Add_MouseLeftButtonUp({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'קבצי הפעלה (*.exe;*.dll;*.msi;*.sys)|*.exe;*.dll;*.msi;*.sys|כל הקבצים (*.*)|*.*'
    if ($dlg.ShowDialog($win)) { Open-File $dlg.FileName }
})

$ui.BtnMin.Add_Click({ $win.WindowState = 'Minimized' })
$ui.BtnMax.Add_Click({ $win.WindowState = if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
$ui.BtnClose.Add_Click({ $win.Close() })
$win.Add_StateChanged({
    # WindowChrome maximizes slightly past the screen edge; pad it back in.
    if ($win.WindowState -eq 'Maximized') { $ui.Root.Margin = '7'; $ui.BtnMax.Content = [string][char]0xE923 }
    else { $ui.Root.Margin = '0'; $ui.BtnMax.Content = [string][char]0xE922 }
})

$ui.TxtPublisher.Add_LostFocus({ Update-Cert; Save-Settings })
$ui.ChkTs.Add_Click({ Save-Settings })
$ui.BtnSign.Add_Click({ Start-Sign })
$ui.BtnLog.Add_Click({ $ui.LogPanel.Visibility = if ($ui.LogPanel.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' } })
$ui.BtnOpen.Add_Click({ if ($script:LastOutput) { Start-Process explorer.exe "/select,`"$($script:LastOutput)`"" } })

$ui.ModeAuto.Add_Checked({ Set-Mode 'auto'; Save-Settings })
$ui.ModeExisting.Add_Checked({ Set-Mode 'existing'; Save-Settings })
$ui.CertList.Add_SelectionChanged({
    if ($script:FillingList) { return }
    Update-Cert; Save-Settings
})
$ui.BtnPfx.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'קובצי תעודה (*.pfx;*.p12;*.cer;*.crt;*.pem;*.der)|*.pfx;*.p12;*.cer;*.crt;*.pem;*.der|כל הקבצים (*.*)|*.*'
    if ($dlg.ShowDialog($win)) { Import-CertFromUi $dlg.FileName $ui.PfxPassword.SecurePassword }
})

$ui.BtnTrust.Add_Click({
    $c = Get-SelectedCert
    if (-not $c) { return }
    try {
        if (Install-SignerTrust $c) { Write-Log 'Certificate is now trusted for this user on this PC.'; Show-Banner 'ok' 'התעודה מאושרת עכשיו במחשב הזה.' }
        else { Show-Banner 'warn' 'התעודה לא נוספה (האישור של Windows בוטל?).' }
    } catch { Write-Log ("ERROR: " + $_.Exception.Message); Show-Banner 'bad' $_.Exception.Message }
    Update-Cert
    $f = if ($script:LastOutput) { $script:LastOutput } else { $script:CurrentFile }
    if ($f) { [void](Show-Report $f) }
})

$ui.BtnExport.Add_Click({
    $c = Get-SelectedCert
    if (-not $c) { return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'Certificate (*.cer)|*.cer'
    $dlg.FileName = ((Get-CertDisplayName $c) -replace '[\\/:*?"<>|]', '_') + '-codesign.cer'
    if ($dlg.ShowDialog($win)) {
        Export-SignerCert $c $dlg.FileName
        Write-Log ("Exported public certificate to " + $dlg.FileName)
        Show-Banner 'ok' 'התעודה יוצאה. במחשב אחר: לחיצה כפולה על הקובץ, Install Certificate, ולהתקין ב-Trusted Root וב-Trusted Publishers.'
    }
})

# --- start ------------------------------------------------------------------
$ui.TxtPublisher.Text = $settings.Publisher
$ui.ChkTs.IsChecked = $settings.Timestamp
$script:PfxCert = $null
if ($PfxPath) {
    # automation: password comes from the EXESIGNER_PFX_PASSWORD environment variable
    $pw = New-Object System.Security.SecureString
    if ($env:EXESIGNER_PFX_PASSWORD) { foreach ($ch in $env:EXESIGNER_PFX_PASSWORD.ToCharArray()) { $pw.AppendChar($ch) } }
    $settings.Mode = 'existing'
    Set-Mode 'existing'
    Import-CertFromUi $PfxPath $pw $CertKeyPath -NoKeyPrompt
} else {
    Set-Mode $settings.Mode
}
Write-Log 'Ready. Drop an EXE to inspect it.'
if ($ShowLog) { $ui.LogPanel.Visibility = 'Visible' }

if ($Screenshot) {
    $win.WindowStartupLocation = 'Manual'; $win.Left = -20000; $win.Top = 0; $win.ShowActivated = $false
}

$win.Add_ContentRendered({
    if ($InitialFile) { Open-File $InitialFile }
    if ($InitialFile -and $AutoSign) { Start-Sign }
    if ($Screenshot) {
        $script:ShotStarted = Get-Date
        $script:ShotTimer = New-Object Windows.Threading.DispatcherTimer
        $script:ShotTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
        $script:ShotTimer.Add_Tick({
            # with -AutoSign, wait for signing to finish (max 60s)
            if ($script:SignJob -and ((Get-Date) - $script:ShotStarted).TotalSeconds -lt 60) { return }
            $script:ShotTimer.Stop()
            $root = $ui.Root
            $scale = 1.5
            $w = $root.ActualWidth; $h = $root.ActualHeight
            # Rendering an element of a right-to-left window directly comes out mirrored; flip it back.
            $dv = New-Object Windows.Media.DrawingVisual
            $dc = $dv.RenderOpen()
            $dc.PushTransform((New-Object Windows.Media.MatrixTransform -1, 0, 0, 1, $w, 0))
            $vb = New-Object Windows.Media.VisualBrush $root
            $dc.DrawRectangle($vb, $null, (New-Object Windows.Rect 0, 0, $w, $h))
            $dc.Close()
            $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]($w * $scale)), ([int]($h * $scale)), (96 * $scale), (96 * $scale), ([Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($dv)
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $fs = [IO.File]::Create($Screenshot)
            try { $enc.Save($fs) } finally { $fs.Dispose() }
            $win.Close()
        })
        $script:ShotTimer.Start()
    }
})

[void]$win.ShowDialog()
