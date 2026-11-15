#import <Cocoa/Cocoa.h>

static NSString * const AOAppName = @"AI Orchestrator Legacy";
static NSString * const AOSelectedModelDefaultsKey = @"AOSelectedModelPath";
static NSString * const AODarkThemeDefaultsKey = @"AODarkThemeEnabled";
static const NSInteger AOLabelTag = 7101;
static const NSInteger AOInputTag = 7102;

@interface AOBackgroundView : NSView
@property(nonatomic, strong) NSColor *fillColor;
@end

@implementation AOBackgroundView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [self.fillColor ?: [NSColor windowBackgroundColor] setFill];
    NSRectFill(self.bounds);
}
@end

@interface AOAppDelegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSSegmentedControl *navigationControl;
@property(nonatomic, strong) AOBackgroundView *rootView;
@property(nonatomic, strong) AOBackgroundView *assistantView;
@property(nonatomic, strong) AOBackgroundView *settingsView;
@property(nonatomic, strong) NSTextView *transcriptView;
@property(nonatomic, strong) NSTextField *promptField;
@property(nonatomic, strong) NSTextField *modelLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *sendButton;
@property(nonatomic, strong) NSButton *chooseButton;
@property(nonatomic, strong) NSButton *darkThemeCheckbox;
@property(nonatomic, strong) NSPopUpButton *settingsModelPopup;
@property(nonatomic, strong) NSTextField *diagnosticsStatusLabel;
@property(nonatomic, strong) NSTextField *updatesStatusLabel;
@property(nonatomic, copy) NSString *modelPath;
@property(nonatomic, strong) NSTask *runningTask;
@property(nonatomic) BOOL darkThemeEnabled;
@end

@implementation AOAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.darkThemeEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:AODarkThemeDefaultsKey];
    [self buildWindow];
    [self restoreSelectedModel];
    [self refreshSettingsModelPopup];
    [self applyTheme];
    [self appendTranscript:@"AI Orchestrator Legacy pronto.\nSeleziona un modello GGUF e scrivi un messaggio.\n\n"];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 820, 620);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled |
                                                         NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable |
                                                         NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = AOAppName;
    self.window.minSize = NSMakeSize(680, 520);
    [self.window center];

    self.rootView = [[AOBackgroundView alloc] initWithFrame:self.window.contentView.bounds];
    self.rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.window.contentView = self.rootView;

    CGFloat width = NSWidth(self.rootView.bounds);
    CGFloat height = NSHeight(self.rootView.bounds);

    self.navigationControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(20, height - 44, 270, 28)];
    self.navigationControl.segmentCount = 2;
    [self.navigationControl setLabel:@"Assistente" forSegment:0];
    [self.navigationControl setLabel:@"Impostazioni" forSegment:1];
    self.navigationControl.trackingMode = NSSegmentSwitchTrackingSelectOne;
    self.navigationControl.selectedSegment = 0;
    self.navigationControl.target = self;
    self.navigationControl.action = @selector(navigationChanged:);
    self.navigationControl.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.rootView addSubview:self.navigationControl];

    NSRect pageFrame = NSMakeRect(0, 0, width, height - 55);
    self.assistantView = [[AOBackgroundView alloc] initWithFrame:pageFrame];
    self.assistantView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.rootView addSubview:self.assistantView];

    self.settingsView = [[AOBackgroundView alloc] initWithFrame:pageFrame];
    self.settingsView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.settingsView.hidden = YES;
    [self.rootView addSubview:self.settingsView];

    [self buildAssistantView];
    [self buildSettingsView];
}

- (void)buildAssistantView {
    NSView *content = self.assistantView;
    CGFloat width = NSWidth(content.bounds);
    CGFloat height = NSHeight(content.bounds);

    NSTextField *title = [self labelWithFrame:NSMakeRect(20, height - 45, width - 40, 24)
                                         text:@"AI Orchestrator — High Sierra / Low Resource"];
    title.font = [NSFont boldSystemFontOfSize:16.0];
    title.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:title];

    self.statusLabel = [self labelWithFrame:NSMakeRect(20, height - 70, width - 40, 18)
                                       text:@"CPU-only • 2 thread • contesto ridotto • nessun Metal"];
    self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.statusLabel];

    self.chooseButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, height - 110, 140, 30)];
    self.chooseButton.title = @"Scegli GGUF…";
    self.chooseButton.bezelStyle = NSBezelStyleRounded;
    self.chooseButton.target = self;
    self.chooseButton.action = @selector(chooseModel:);
    self.chooseButton.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [content addSubview:self.chooseButton];

    self.modelLabel = [self labelWithFrame:NSMakeRect(170, height - 104, width - 190, 20)
                                      text:@"Nessun modello selezionato"];
    self.modelLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.modelLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.modelLabel];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 105, width - 40, height - 225)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.transcriptView = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
    self.transcriptView.editable = NO;
    self.transcriptView.selectable = YES;
    self.transcriptView.font = [NSFont systemFontOfSize:13.0];
    self.transcriptView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.documentView = self.transcriptView;
    [content addSubview:scroll];

    self.promptField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 55, width - 135, 30)];
    self.promptField.placeholderString = @"Scrivi un messaggio…";
    self.promptField.delegate = self;
    self.promptField.tag = AOInputTag;
    self.promptField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:self.promptField];

    self.sendButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 105, 53, 85, 32)];
    self.sendButton.title = @"Invia";
    self.sendButton.bezelStyle = NSBezelStyleRounded;
    self.sendButton.target = self;
    self.sendButton.action = @selector(sendPrompt:);
    self.sendButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:self.sendButton];

    NSTextField *footer = [self labelWithFrame:NSMakeRect(20, 20, width - 40, 18)
                                          text:@"Modalità legacy: ottimizzata per Mac Intel con memoria limitata."];
    footer.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:footer];
}

- (void)buildSettingsView {
    NSView *content = self.settingsView;
    CGFloat width = NSWidth(content.bounds);
    CGFloat height = NSHeight(content.bounds);

    NSTextField *title = [self labelWithFrame:NSMakeRect(24, height - 48, width - 48, 24)
                                         text:@"Impostazioni"];
    title.font = [NSFont boldSystemFontOfSize:18.0];
    title.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:title];

    [content addSubview:[self sectionLabelWithFrame:NSMakeRect(24, height - 92, 220, 20) text:@"Aspetto"]];
    self.darkThemeCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(24, height - 122, 260, 24)];
    self.darkThemeCheckbox.buttonType = NSSwitchButton;
    self.darkThemeCheckbox.title = @"Tema scuro (ottimizzato High Sierra)";
    self.darkThemeCheckbox.state = self.darkThemeEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.darkThemeCheckbox.target = self;
    self.darkThemeCheckbox.action = @selector(darkThemeChanged:);
    self.darkThemeCheckbox.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [content addSubview:self.darkThemeCheckbox];

    [content addSubview:[self sectionLabelWithFrame:NSMakeRect(24, height - 165, 220, 20) text:@"Modelli"]];
    self.settingsModelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24, height - 202, 320, 28) pullsDown:NO];
    self.settingsModelPopup.target = self;
    self.settingsModelPopup.action = @selector(settingsModelChanged:);
    self.settingsModelPopup.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [content addSubview:self.settingsModelPopup];

    NSButton *importButton = [[NSButton alloc] initWithFrame:NSMakeRect(355, height - 203, 120, 30)];
    importButton.title = @"Importa GGUF…";
    importButton.bezelStyle = NSBezelStyleRounded;
    importButton.target = self;
    importButton.action = @selector(chooseModel:);
    importButton.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [content addSubview:importButton];

    NSButton *folderButton = [[NSButton alloc] initWithFrame:NSMakeRect(485, height - 203, 135, 30)];
    folderButton.title = @"Apri cartella modelli";
    folderButton.bezelStyle = NSBezelStyleRounded;
    folderButton.target = self;
    folderButton.action = @selector(openModelsFolder:);
    folderButton.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [content addSubview:folderButton];

    [content addSubview:[self sectionLabelWithFrame:NSMakeRect(24, height - 248, 220, 20) text:@"Diagnostics"]];
    self.diagnosticsStatusLabel = [self labelWithFrame:NSMakeRect(24, height - 278, width - 190, 20)
                                                   text:@"Diagnostics locale pronto • collegamento remoto da integrare"];
    self.diagnosticsStatusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.diagnosticsStatusLabel];

    NSButton *copyDiagnosticsButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 155, height - 285, 130, 30)];
    copyDiagnosticsButton.title = @"Copia diagnostica";
    copyDiagnosticsButton.bezelStyle = NSBezelStyleRounded;
    copyDiagnosticsButton.target = self;
    copyDiagnosticsButton.action = @selector(copyDiagnostics:);
    copyDiagnosticsButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [content addSubview:copyDiagnosticsButton];

    [content addSubview:[self sectionLabelWithFrame:NSMakeRect(24, height - 328, 220, 20) text:@"Aggiornamenti"]];
    self.updatesStatusLabel = [self labelWithFrame:NSMakeRect(24, height - 358, width - 48, 20)
                                              text:[NSString stringWithFormat:@"Versione %@ • canale High Sierra Legacy • updater automatico: prossimo step", [self appVersionString]]];
    self.updatesStatusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.updatesStatusLabel];

    [content addSubview:[self sectionLabelWithFrame:NSMakeRect(24, height - 408, 220, 20) text:@"AI / Runtime"]];
    NSTextField *runtime = [self labelWithFrame:NSMakeRect(24, height - 438, width - 48, 20)
                                           text:@"Modalità locale • llama.cpp CPU-only • 2 thread • contesto 1024 • nessun Metal"];
    runtime.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:runtime];

    [content addSubview:[self sectionLabelWithFrame:NSMakeRect(24, height - 488, 220, 20) text:@"Informazioni"]];
    unsigned long long ramMB = [NSProcessInfo processInfo].physicalMemory / (1024ULL * 1024ULL);
    NSString *info = [NSString stringWithFormat:@"%@ • %@ • RAM %llu MB", AOAppName,
                      [NSProcessInfo processInfo].operatingSystemVersionString, ramMB];
    NSTextField *infoLabel = [self labelWithFrame:NSMakeRect(24, height - 518, width - 48, 20) text:info];
    infoLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:infoLabel];
}

- (NSTextField *)labelWithFrame:(NSRect)frame text:(NSString *)text {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.stringValue = text ?: @"";
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.editable = NO;
    field.selectable = NO;
    field.tag = AOLabelTag;
    return field;
}

- (NSTextField *)sectionLabelWithFrame:(NSRect)frame text:(NSString *)text {
    NSTextField *field = [self labelWithFrame:frame text:text];
    field.font = [NSFont boldSystemFontOfSize:14.0];
    return field;
}

- (void)navigationChanged:(id)sender {
    (void)sender;
    BOOL showSettings = self.navigationControl.selectedSegment == 1;
    self.assistantView.hidden = showSettings;
    self.settingsView.hidden = !showSettings;
    if (showSettings) {
        [self refreshSettingsModelPopup];
    }
}

- (void)darkThemeChanged:(id)sender {
    (void)sender;
    self.darkThemeEnabled = self.darkThemeCheckbox.state == NSControlStateValueOn;
    [[NSUserDefaults standardUserDefaults] setBool:self.darkThemeEnabled forKey:AODarkThemeDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self applyTheme];
}

- (void)applyTheme {
    NSColor *background = self.darkThemeEnabled
        ? [NSColor colorWithCalibratedRed:0.10 green:0.11 blue:0.13 alpha:1.0]
        : [NSColor windowBackgroundColor];
    NSColor *pageBackground = self.darkThemeEnabled
        ? [NSColor colorWithCalibratedRed:0.13 green:0.14 blue:0.16 alpha:1.0]
        : [NSColor windowBackgroundColor];
    self.rootView.fillColor = background;
    self.assistantView.fillColor = pageBackground;
    self.settingsView.fillColor = pageBackground;
    [self.rootView setNeedsDisplay:YES];
    [self.assistantView setNeedsDisplay:YES];
    [self.settingsView setNeedsDisplay:YES];
    [self applyThemeToView:self.rootView];
}

- (void)applyThemeToView:(NSView *)view {
    NSColor *textColor = self.darkThemeEnabled ? [NSColor colorWithCalibratedWhite:0.92 alpha:1.0] : [NSColor labelColor];
    NSColor *inputBackground = self.darkThemeEnabled ? [NSColor colorWithCalibratedWhite:0.18 alpha:1.0] : [NSColor textBackgroundColor];
    NSColor *transcriptBackground = self.darkThemeEnabled ? [NSColor colorWithCalibratedWhite:0.08 alpha:1.0] : [NSColor textBackgroundColor];

    if ([view isKindOfClass:[NSTextField class]]) {
        NSTextField *field = (NSTextField *)view;
        if (field.tag == AOLabelTag) {
            field.textColor = textColor;
        } else if (field.tag == AOInputTag) {
            field.textColor = textColor;
            field.drawsBackground = YES;
            field.backgroundColor = inputBackground;
        }
    } else if ([view isKindOfClass:[NSTextView class]] && view == self.transcriptView) {
        NSTextView *textView = (NSTextView *)view;
        textView.textColor = textColor;
        textView.backgroundColor = transcriptBackground;
        textView.insertionPointColor = textColor;
    }

    for (NSView *subview in view.subviews) {
        [self applyThemeToView:subview];
    }
}

- (NSURL *)modelsDirectoryURLCreatingIfNeeded:(BOOL)create error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *urls = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
    NSURL *baseURL = urls.firstObject;
    if (!baseURL) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIOrchestratorLegacy"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Directory Application Support non disponibile."}];
        }
        return nil;
    }
    NSURL *modelsURL = [[baseURL URLByAppendingPathComponent:@"AI Orchestrator Legacy" isDirectory:YES]
                        URLByAppendingPathComponent:@"Models" isDirectory:YES];
    if (create && ![fm createDirectoryAtURL:modelsURL withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }
    return modelsURL;
}

- (void)refreshSettingsModelPopup {
    if (!self.settingsModelPopup) return;
    [self.settingsModelPopup removeAllItems];
    [self.settingsModelPopup addItemWithTitle:@"Nessun modello selezionato"];

    NSError *error = nil;
    NSURL *modelsURL = [self modelsDirectoryURLCreatingIfNeeded:YES error:&error];
    if (!modelsURL || error) return;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:modelsURL
                                                   includingPropertiesForKeys:nil
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                        error:&error];
    if (!items || error) return;
    NSArray *sorted = [items sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.lastPathComponent localizedCaseInsensitiveCompare:right.lastPathComponent];
    }];
    for (NSURL *url in sorted) {
        if ([[url.pathExtension lowercaseString] isEqualToString:@"gguf"]) {
            [self.settingsModelPopup addItemWithTitle:url.lastPathComponent];
            self.settingsModelPopup.lastItem.representedObject = url.path;
        }
    }
    if (self.modelPath.length > 0) {
        for (NSMenuItem *item in self.settingsModelPopup.itemArray) {
            if ([item.representedObject isEqual:self.modelPath]) {
                [self.settingsModelPopup selectItem:item];
                return;
            }
        }
    }
    [self.settingsModelPopup selectItemAtIndex:0];
}

- (void)settingsModelChanged:(id)sender {
    (void)sender;
    NSString *path = self.settingsModelPopup.selectedItem.representedObject;
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        return;
    }
    NSString *reason = nil;
    if (![self validateGGUFAtPath:path reason:&reason]) {
        [self showError:reason ?: @"Modello non valido."];
        return;
    }
    [self selectModelAtPath:path announce:YES];
}

- (void)restoreSelectedModel {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:AOSelectedModelDefaultsKey];
    if (saved.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:saved]) return;
    NSString *reason = nil;
    if ([self validateGGUFAtPath:saved reason:&reason]) {
        [self selectModelAtPath:saved announce:NO];
    }
}

- (void)selectModelAtPath:(NSString *)path announce:(BOOL)announce {
    self.modelPath = [path copy];
    self.modelLabel.stringValue = path.lastPathComponent;
    self.statusLabel.stringValue = @"Modello pronto • CPU-only • 2 thread • contesto 1024";
    [[NSUserDefaults standardUserDefaults] setObject:path forKey:AOSelectedModelDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (announce) {
        [self appendTranscript:[NSString stringWithFormat:@"Modello: %@\n\n", path.lastPathComponent]];
    }
    [self refreshSettingsModelPopup];
}

- (void)chooseModel:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedFileTypes = @[@"gguf"];

    if ([panel runModal] != NSModalResponseOK) return;

    NSString *sourcePath = panel.URL.path;
    NSString *reason = nil;
    if (![self validateGGUFAtPath:sourcePath reason:&reason]) {
        [self showError:reason ?: @"Il file selezionato non è un GGUF valido."];
        return;
    }

    NSError *copyError = nil;
    NSString *privatePath = [self importModelAtPath:sourcePath error:&copyError];
    if (!privatePath) {
        [self showError:[NSString stringWithFormat:@"Impossibile importare il modello: %@",
                         copyError.localizedDescription ?: @"errore sconosciuto"]];
        return;
    }
    [self selectModelAtPath:privatePath announce:YES];
}

- (BOOL)validateGGUFAtPath:(NSString *)path reason:(NSString **)reason {
    if (path.length == 0 || ![[path.pathExtension lowercaseString] isEqualToString:@"gguf"]) {
        if (reason) *reason = @"Seleziona un file con estensione .gguf.";
        return NO;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        if (reason) *reason = @"Il file non è leggibile.";
        return NO;
    }
    NSData *header = [handle readDataOfLength:4];
    [handle closeFile];
    const unsigned char expected[4] = {'G', 'G', 'U', 'F'};
    if (header.length != 4 || memcmp(header.bytes, expected, 4) != 0) {
        if (reason) *reason = @"Il file non contiene un header GGUF valido.";
        return NO;
    }
    return YES;
}

- (NSString *)importModelAtPath:(NSString *)sourcePath error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *modelsURL = [self modelsDirectoryURLCreatingIfNeeded:YES error:error];
    if (!modelsURL) return nil;

    NSString *baseName = sourcePath.lastPathComponent;
    NSString *stem = [baseName stringByDeletingPathExtension];
    NSString *safeStem = [self sanitizedFileComponent:stem];
    if (safeStem.length == 0) safeStem = @"model";
    NSString *candidate = [safeStem stringByAppendingPathExtension:@"gguf"];
    NSURL *destination = [modelsURL URLByAppendingPathComponent:candidate];
    NSUInteger suffix = 2;
    while ([fm fileExistsAtPath:destination.path]) {
        candidate = [[NSString stringWithFormat:@"%@-%lu", safeStem, (unsigned long)suffix++] stringByAppendingPathExtension:@"gguf"];
        destination = [modelsURL URLByAppendingPathComponent:candidate];
    }

    if (![fm copyItemAtURL:[NSURL fileURLWithPath:sourcePath] toURL:destination error:error]) return nil;

    NSString *reason = nil;
    if (![self validateGGUFAtPath:destination.path reason:&reason]) {
        [fm removeItemAtURL:destination error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"AIOrchestratorLegacy"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: reason ?: @"Copia GGUF non valida."}];
        }
        return nil;
    }
    return destination.path;
}

- (NSString *)sanitizedFileComponent:(NSString *)value {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. "];
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if ([allowed characterIsMember:c]) [result appendFormat:@"%C", c];
        else [result appendString:@"_"];
    }
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)openModelsFolder:(id)sender {
    (void)sender;
    NSError *error = nil;
    NSURL *url = [self modelsDirectoryURLCreatingIfNeeded:YES error:&error];
    if (!url || error) {
        [self showError:error.localizedDescription ?: @"Cartella modelli non disponibile."];
        return;
    }
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
}

- (NSString *)appVersionString {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
    if (version.length == 0) version = @"0.0.0";
    if (build.length == 0) return version;
    return [NSString stringWithFormat:@"%@ (%@)", version, build];
}

- (NSString *)diagnosticsSummary {
    unsigned long long ramMB = [NSProcessInfo processInfo].physicalMemory / (1024ULL * 1024ULL);
    NSString *model = self.modelPath.lastPathComponent ?: @"none";
    return [NSString stringWithFormat:
            @"AI_ORCHESTRATOR_LEGACY_DIAGNOSTICS\nversion=%@\nos=%@\nram_mb=%llu\nmodel=%@\nruntime=llama.cpp cpu-only\nthreads=2\ncontext=1024\nmetal=false\ndark_theme=%@\n",
            [self appVersionString],
            [NSProcessInfo processInfo].operatingSystemVersionString,
            ramMB,
            model,
            self.darkThemeEnabled ? @"true" : @"false"];
}

- (void)copyDiagnostics:(id)sender {
    (void)sender;
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:[self diagnosticsSummary] forType:NSPasteboardTypeString];
    self.diagnosticsStatusLabel.stringValue = @"Diagnostica copiata negli appunti • invio remoto da integrare";
}

- (void)sendPrompt:(id)sender {
    (void)sender;
    NSString *prompt = [self.promptField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (prompt.length == 0) return;
    if (self.modelPath.length == 0) {
        [self showError:@"Seleziona prima un modello GGUF."];
        return;
    }
    if (self.runningTask) {
        [self showError:@"È già in corso una generazione."];
        return;
    }

    NSString *helper = [[NSBundle mainBundle] pathForResource:@"llama-cli" ofType:nil];
    if (helper.length == 0 || ![[NSFileManager defaultManager] isExecutableFileAtPath:helper]) {
        [self showError:@"Runtime locale llama-cli non trovato nel bundle."];
        return;
    }

    self.promptField.stringValue = @"";
    self.sendButton.enabled = NO;
    self.chooseButton.enabled = NO;
    self.statusLabel.stringValue = @"Generazione in corso…";
    [self appendTranscript:[NSString stringWithFormat:@"Tu: %@\nAI: ", prompt]];

    NSString *model = [self.modelPath copy];
    [self performSelectorInBackground:@selector(runInferencePayload:) withObject:@{ @"helper": helper, @"model": model, @"prompt": prompt }];
}

- (void)runInferencePayload:(NSDictionary *)payload {
    @autoreleasepool {
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = payload[@"helper"];
        task.arguments = @[
            @"-m", payload[@"model"],
            @"-p", payload[@"prompt"],
            @"-t", @"2",
            @"-c", @"1024",
            @"-n", @"128",
            @"--temp", @"0.7",
            @"--top-p", @"0.9",
            @"--top-k", @"40"
        ];

        NSPipe *outPipe = [NSPipe pipe];
        NSPipe *errPipe = [NSPipe pipe];
        task.standardOutput = outPipe;
        task.standardError = errPipe;
        self.runningTask = task;

        NSString *result = nil;
        NSString *errorText = nil;
        @try {
            [task launch];
            NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
            NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
            [task waitUntilExit];
            result = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
            errorText = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
            if (task.terminationStatus != 0 && errorText.length == 0) {
                errorText = [NSString stringWithFormat:@"llama-cli terminato con codice %d", task.terminationStatus];
            }
        } @catch (NSException *exception) {
            errorText = exception.reason ?: @"Impossibile avviare llama-cli.";
        }

        NSDictionary *completion = @{ @"result": result ?: @"", @"error": errorText ?: @"" };
        [self performSelectorOnMainThread:@selector(finishInference:) withObject:completion waitUntilDone:NO];
    }
}

- (void)finishInference:(NSDictionary *)completion {
    self.runningTask = nil;
    self.sendButton.enabled = YES;
    self.chooseButton.enabled = YES;
    NSString *result = [completion[@"result"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *error = [completion[@"error"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (result.length > 0) {
        [self appendTranscript:[result stringByAppendingString:@"\n\n"]];
        self.statusLabel.stringValue = @"Pronto • CPU-only • 2 thread • contesto 1024";
    } else {
        [self appendTranscript:@"[nessuna risposta]\n\n"];
        self.statusLabel.stringValue = @"Errore di generazione";
    }
    if (result.length == 0 && error.length > 0) [self showError:error];
}

- (void)appendTranscript:(NSString *)text {
    if (text.length == 0) return;
    NSTextStorage *storage = self.transcriptView.textStorage;
    [storage appendAttributedString:[[NSAttributedString alloc] initWithString:text]];
    [self.transcriptView scrollRangeToVisible:NSMakeRange(storage.length, 0)];
}

- (void)showError:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = AOAppName;
    alert.informativeText = message ?: @"Errore sconosciuto";
    alert.alertStyle = NSAlertStyleWarning;
    [alert runModal];
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    if (obj.object == self.promptField && [obj.userInfo[@"NSTextMovement"] integerValue] == NSReturnTextMovement) {
        [self sendPrompt:nil];
    }
}

@end

static int RunSelfTest(void) {
    NSString *helper = [[NSBundle mainBundle] pathForResource:@"llama-cli" ofType:nil];
    if (helper.length == 0 || ![[NSFileManager defaultManager] isExecutableFileAtPath:helper]) {
        fprintf(stderr, "SELF_TEST_FAIL helper_missing\n");
        return 2;
    }
    printf("SELF_TEST_OK helper=%s\n", helper.fileSystemRepresentation);
    return 0;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--self-test") == 0) return RunSelfTest();
        }
        NSApplication *app = [NSApplication sharedApplication];
        AOAppDelegate *delegate = [[AOAppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
