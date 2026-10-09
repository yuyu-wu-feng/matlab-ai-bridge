function result = bridge_probe(outputRoot)
% Test public editor APIs using only documents created by this function.
% Existing user documents are neither read nor modified.
if ~isfolder(outputRoot), mkdir(outputRoot); end
probeDir = tempname(outputRoot);
mkdir(probeDir);
checks = struct;
originalActive = matlab.desktop.editor.getActive;
restoreActive = onCleanup(@() restoreDocument(originalActive));
try
    baseline = sprintf('%% 中文连接测试\nx = 1;\ny = x + 2;\n');
    doc = matlab.desktop.editor.newDocument(baseline);
    closeFirst = onCleanup(@() closeDocument(doc));
    checks.untitled_buffer = strcmp(char(doc.Text), baseline) && doc.Opened;
    doc.makeActive;
    active = matlab.desktop.editor.getActive;
    checks.active_document = isequal(active, doc);
    checks.untitled_identity = doc.Filename;

    doc.Selection = [2 1 3 7];
    checks.multiline_selection = strcmp(char(doc.SelectedText), ...
        sprintf('x = 1;\ny = x '));
    checks.selection_coordinates = isequal(doc.Selection, [2 1 3 7]);
    doc.Selection = [2 3 2 3];
    checks.cursor = isequal(doc.Selection, [2 3 2 3]) && isempty(doc.SelectedText);

    doc.Text = [baseline '% unsaved buffer'];
    checks.unsaved_buffer_read = strcmp(char(doc.Text), [baseline '% unsaved buffer']);
    checks.unsaved_modified_flag = doc.Modified;
    doc.Text = baseline;
    checks.snapshot_restore = strcmp(char(doc.Text), baseline);

    % Open a second document; keep modifying the captured first document.
    second = matlab.desktop.editor.newDocument('% second probe document');
    closeSecond = onCleanup(@() closeDocument(second));
    second.makeActive;
    doc.Text = strrep(baseline, 'x = 1;', 'x = 42;');
    checks.target_after_tab_switch = contains(char(doc.Text), 'x = 42;') ...
        && strcmp(char(second.Text), '% second probe document');
    doc.Text = baseline;

    % Programmatic range replacement. Verify prefix and suffix preservation.
    doc.Selection = [2 1 2 7];
    startIndex = matlab.desktop.editor.positionInLineToIndex(doc, 2, 1);
    endIndex = matlab.desktop.editor.positionInLineToIndex(doc, 2, 7);
    snapshot = char(doc.Text);
    doc.Text = [snapshot(1:startIndex-1) 'x = 99;' snapshot(endIndex:end)];
    checks.range_write = strcmp(char(doc.Text), strrep(baseline, 'x = 1;', 'x = 99;'));
    doc.Text = snapshot;
    checks.range_restore = strcmp(char(doc.Text), baseline);

    % Explicitly save only the owned probe, then test dirty-buffer semantics.
    probePath = fullfile(probeDir, '中文编辑器测试.m');
    doc.saveAs(probePath);
    savedText = char(doc.Text);
    savedDisk = fileread(probePath);
    doc.Text = [savedText '% buffer-only change'];
    checks.saved_file_dirty_buffer = doc.Modified && ...
        contains(char(doc.Text), '% buffer-only change');
    checks.no_implicit_save = strcmp(fileread(probePath), savedDisk);
    doc.Text = savedText;
    checks.saved_buffer_restore = strcmp(char(doc.Text), savedText);
    checks.chinese_path = strcmp(doc.Filename, probePath);
    checks.chinese_text = contains(char(doc.Text), '中文连接测试');
    report = struct('ok', true, 'release', version('-release'), ...
        'version', version, 'checks', checks, 'probe_directory', probeDir, ...
        'native_undo', 'NOT_TESTED; snapshot restoration only', ...
        'ai_backend', 'NOT_CONNECTED');
    names = fieldnames(checks);
    for k = 1:numel(names)
        value = checks.(names{k});
        if islogical(value), report.ok = report.ok && all(value(:)); end
    end
catch exception
    report = struct('ok', false, 'release', version('-release'), ...
        'checks', checks, 'error_id', exception.identifier, ...
        'error_message', exception.message);
end
result = jsonencode(report);
end

function closeDocument(doc)
if doc.Opened, doc.closeNoPrompt; end
end

function restoreDocument(doc)
if ~isempty(doc) && doc.Opened, doc.makeActive; end
end
