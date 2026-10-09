classdef AIEditorTransaction < handle
    % Capture one document, validate changes, and apply only to that document.
    properties (SetAccess = private)
        Document
        Filename
        BaseText
        Selection
        Scope
        Mode
        Context
        BeforeCursor = ''
        AfterCursor = ''
        StartIndex
        EndIndex
        ProposedText = ''
        Replacement = ''
        Prepared = false
        Applied = false
        Restored = false
        HadFile = false
        DiskBytes = uint8([])
    end
    methods
        function obj = AIEditorTransaction(doc, mode, scope)
            if isempty(doc) || ~doc.Opened
                error('MatlabAI:NoDocument', '请先在 MATLAB 编辑器打开一个 .m 文件。');
            end
            [~,~,extension] = fileparts(doc.Filename);
            if ~isempty(extension) && ~strcmpi(extension, '.m')
                error('MatlabAI:UnsupportedFile', '首版仅支持普通 .m 文件与未保存的新建代码文档。');
            end
            if ~ismember(mode, {'explain','edit','complete'}) || ~ismember(scope, {'file','selection','cursor'})
                error('MatlabAI:InvalidMode', '操作类型或上下文范围无效。');
            end
            obj.Document = doc;
            obj.Filename = doc.Filename;
            obj.BaseText = char(doc.Text);
            obj.Selection = doc.Selection;
            obj.Mode = mode;
            if strcmp(mode, 'complete'), scope = 'cursor'; end
            if strcmp(scope, 'cursor') && ~strcmp(mode, 'complete')
                error('MatlabAI:InvalidScope', '光标插入仅适用于续写。请选择当前文件或选中代码。');
            end
            obj.Scope = scope;
            obj.StartIndex = 1;
            obj.EndIndex = numel(obj.BaseText) + 1;
            if ismember(scope, {'selection','cursor'})
                s = obj.Selection;
                if any(s < 1), error('MatlabAI:Selection', '无法读取有效的代码选区。'); end
                % Map against this exact buffer: platform newline settings can
                % differ from the actual Text returned by the R2026a editor.
                obj.StartIndex = bufferIndex(obj.BaseText, s(1), s(2));
                obj.EndIndex = bufferIndex(obj.BaseText, s(3), s(4));
                if strcmp(scope, 'selection') && obj.StartIndex == obj.EndIndex
                    error('MatlabAI:EmptySelection', '请先在编辑器中选中需要处理的代码。');
                end
                if strcmp(scope, 'cursor')
                    if obj.StartIndex ~= obj.EndIndex
                        error('MatlabAI:CursorSelection', '插入前请取消选区，将光标放在要插入代码的位置。');
                    end
                    obj.BeforeCursor = obj.BaseText(1:obj.StartIndex-1);
                    obj.AfterCursor = obj.BaseText(obj.StartIndex:end);
                end
            end
            if strcmp(scope, 'cursor')
                obj.Context = obj.BaseText;
            else
                obj.Context = obj.BaseText(obj.StartIndex:obj.EndIndex-1);
            end
            if numel(obj.Context) > 300000
                error('MatlabAI:ContextLimit', '代码过长，请选择更小的代码范围。');
            end
            obj.HadFile = isfile(obj.Filename);
            if obj.HadFile, obj.DiskBytes = readBytes(obj.Filename); end
        end

        function propose(obj, replacement)
            if strcmp(obj.Mode, 'explain')
                error('MatlabAI:ExplainReadOnly', '解释操作不能产生代码修改。');
            end
            if obj.Applied || obj.Restored
                error('MatlabAI:AlreadyApplied', '该请求已处理，请重新提问。');
            end
            if ~(ischar(replacement) && isrow(replacement)) && ~(isstring(replacement) && isscalar(replacement))
                error('MatlabAI:InvalidResponse', '替换内容必须是文本。');
            end
            replacement = char(replacement);
            if isempty(strtrim(replacement)) || numel(replacement) > 300000 || startsWith(strtrim(replacement), '```')
                error('MatlabAI:InvalidResponse', '返回的代码为空、过长或包含 Markdown 包装。');
            end
            replacement = strrep(replacement, sprintf('\r\n'), newline);
            replacement = strrep(replacement, char(13), newline);
            if contains(obj.BaseText, sprintf('\r\n'))
                replacement = strrep(replacement, newline, sprintf('\r\n'));
            end
            obj.Replacement = replacement;
            obj.ProposedText = [obj.BaseText(1:obj.StartIndex-1) replacement obj.BaseText(obj.EndIndex:end)];
            obj.Prepared = true;
        end

        function apply(obj)
            if ~obj.Prepared || obj.Applied || obj.Restored
                error('MatlabAI:NoProposal', '没有可应用的新修改。');
            end
            obj.checkIdentity;
            previousEditable = obj.Document.Editable;
            if ~previousEditable, error('MatlabAI:ReadOnly', '目标文档当前不可编辑。'); end
            obj.checkUnchanged(obj.BaseText);
            % The public setter requires Editable=true. Do not yield between
            % final comparison and assignment; no undocumented editor locks.
            obj.Document.Text = obj.ProposedText;
            if ~strcmp(char(obj.Document.Text), obj.ProposedText)
                obj.Document.Text = obj.BaseText;
                error('MatlabAI:WriteFailed', '编辑器回写结果不一致，已尝试恢复原文。');
            end
            obj.Applied = true;
        end

        function selectChanges(obj,blocks,selected)
            if ~obj.Prepared || obj.Applied || obj.Restored
                error('MatlabAI:NoProposal','没有可筛选的修改。');
            end
            if numel(selected)~=numel(blocks) || ~any(selected)
                error('MatlabAI:NoSelection','请至少选择一处修改。');
            end
            proposed = obj.BaseText;
            for k=numel(blocks):-1:1
                if selected(k)
                    b = blocks(k);
                    proposed = [proposed(1:b.start-1) b.replacement proposed(b.stop:end)];
                end
            end
            obj.ProposedText = proposed;
        end

        function restore(obj)
            if ~obj.Applied || obj.Restored
                error('MatlabAI:NoRestore', '没有可恢复的修改。');
            end
            obj.checkIdentity;
            previousEditable = obj.Document.Editable;
            if ~previousEditable, error('MatlabAI:ReadOnly', '目标文档当前不可编辑。'); end
            obj.checkUnchanged(obj.ProposedText);
            obj.Document.Text = obj.BaseText;
            if ~strcmp(char(obj.Document.Text), obj.BaseText)
                error('MatlabAI:RestoreFailed', '恢复结果不一致，请保留当前文档并检查内容。');
            end
            obj.Document.Selection = obj.Selection;
            obj.Restored = true;
        end

        function checkIdentity(obj)
            if ~obj.Document.Opened
                error('MatlabAI:Closed', '目标文档已关闭，请重新打开并提问。');
            end
            if ~strcmp(obj.Document.Filename, obj.Filename)
                error('MatlabAI:Renamed', '目标文档已改名或另存为，请重新提问。');
            end
        end

        function checkUnchanged(obj, expected)
            obj.checkIdentity;
            if ~strcmp(char(obj.Document.Text), expected)
                error('MatlabAI:Conflict', '代码已发生变化，已阻止覆盖。请基于最新代码重新提问。');
            end
            if obj.HadFile ~= isfile(obj.Filename) || ...
                    (obj.HadFile && ~isequal(readBytes(obj.Filename), obj.DiskBytes))
                error('MatlabAI:DiskConflict', '磁盘上的文件已变化，已阻止覆盖。请重新读取代码。');
            end
        end
    end
end

function bytes = readBytes(path)
fid = fopen(path, 'rb');
if fid < 0, error('MatlabAI:FileRead', '无法读取目标文件以检查外部修改。'); end
cleanup = onCleanup(@() fclose(fid));
bytes = fread(fid, Inf, '*uint8');
end

function index = bufferIndex(text, line, column)
starts = [1 find(text == char(10)) + 1];
if line < 1 || line > numel(starts) || column < 1
    error('MatlabAI:Selection', '选区超出当前缓冲区范围。');
end
index = starts(line) + column - 1;
if line < numel(starts), limit = starts(line+1)-1; else, limit = numel(text)+1; end
if limit > 1 && text(limit-1) == char(13), limit = limit-1; end
if index > limit, error('MatlabAI:Selection', '选区列号超出当前代码行。'); end
end
