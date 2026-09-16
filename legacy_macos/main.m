#import <Cocoa/Cocoa.h>

static NSString * const AOAppName = @"AI Orchestrator Legacy";

@interface AOAppDelegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextView *transcriptView;
@property(nonatomic, strong) NSTextField *promptField;
@property(nonatomic, strong) NSTextField *modelLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *sendButton;
@property(nonatomic, strong) NSButton *chooseButton;
@property(nonatomic, copy) NSString *modelPath;
@property(nonatomic, strong) NSTask *runningTask;
@end

@implementation AOAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self buildWindow];
    [self appendTranscript:@"AI Orchestrator Legacy pronto.\nSeleziona un modello GGUF e scrivi un messaggio.\n\n"];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 760, 560);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled |
                                                         NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable |
                                                         NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = AOAppName;
    self.window.minSize = NSMakeSize(620, 460);
    [self.window center];

    NSView *content = self.window.contentView;
    CGFloat width = NSWidth(content.bounds);
    CGFloat height = NSHeight(content.bounds);

    NSTextField *title = [self labelWithFrame:NSMakeRect(20, height - 45, width - 40, 24)
                                         text:@"AI Orchestrator — High Sierra / Low Resource"];
    title.font = [NSFont boldSystemFontOfSize:16.0];
    title.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:title];

    self.statusLabel = [self labelWithFrame:NSMakeRect(20, height - 70, width - 40, 18)
                                       text:@"CPU-only • 2 thread • contesto ridotto • nessun Metal"];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
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
    footer.textColor = [NSColor secondaryLabelColor];
    footer.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:footer];
}

- (NSTextField *)labelWithFrame:(NSRect)frame text:(NSString *)text {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.stringValue = text ?: @"";
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.editable = NO;
    field.selectable = NO;
    return field;
}

- (void)chooseModel:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedFileTypes = @[@"gguf"];

    if ([panel runModal] != NSModalResponseOK) {
        return;
    }

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

    self.modelPath = privatePath;
    self.modelLabel.stringValue = privatePath.lastPathComponent;
    self.statusLabel.stringValue = @"Modello pronto • CPU-only • 2 thread • contesto 1024";
    [self appendTranscript:[NSString stringWithFormat:@"Modello: %@\n\n", privatePath.lastPathComponent]];
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
    if (![fm createDirectoryAtURL:modelsURL withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }

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

    if (![fm copyItemAtURL:[NSURL fileURLWithPath:sourcePath] toURL:destination error:error]) {
        return nil;
    }

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
        if ([allowed characterIsMember:c]) {
            [result appendFormat:@"%C", c];
        } else {
            [result appendString:@"_"];
        }
    }
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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

        NSDictionary *completion = @{
            @"result": result ?: @"",
            @"error": errorText ?: @""
        };
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
    if (result.length == 0 && error.length > 0) {
        [self showError:error];
    }
}

- (void)appendTranscript:(NSString *)text {
    if (text.length == 0) return;
    NSTextStorage *storage = self.transcriptView.textStorage;
    [storage appendAttributedString:[[NSAttributedString alloc] initWithString:text]];
    [self.transcriptView scrollRangeToVisible:NSMakeRange(storage.length, 0)];
}

- (void)showError:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"AI Orchestrator Legacy";
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
            if (strcmp(argv[i], "--self-test") == 0) {
                return RunSelfTest();
            }
        }
        NSApplication *app = [NSApplication sharedApplication];
        AOAppDelegate *delegate = [[AOAppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
