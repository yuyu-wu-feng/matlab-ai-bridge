classdef AIConversationStore < handle
    % Local JSON history. Loaded sessions fork on the next save, so independent
    % MATLAB desktops never overwrite one another's conversation files.
    properties (SetAccess = private)
        Folder
        ID
        Turns = struct('question',{},'mode',{},'model',{},'explanation',{},'replacement',{},'time',{})
        Owned = true
    end
    methods
        function obj = AIConversationStore(folder)
            obj.Folder = folder;
            obj.ID = char(java.util.UUID.randomUUID);
            if ~isempty(folder) && ~isfolder(folder), mkdir(folder); end
        end

        function fresh(obj)
            obj.ID = char(java.util.UUID.randomUUID);
            obj.Turns = obj.Turns([]);
            obj.Owned = true;
        end

        function add(obj,question,mode,model,response)
            if ~obj.Owned, obj.ID = char(java.util.UUID.randomUUID); obj.Owned = true; end
            turn = struct('question',char(question),'mode',char(mode),'model',char(model), ...
                'explanation',char(response.explanation),'replacement',char(response.replacement), ...
                'time',char(datetime('now','Format','yyyy-MM-dd HH:mm:ss')));
            obj.Turns(end+1) = turn;
            obj.save;
        end

        function save(obj)
            if isempty(obj.Folder) || isempty(obj.Turns), return; end
            data = struct('version',1,'id',obj.ID,'turns',obj.Turns);
            target = fullfile(obj.Folder,[obj.ID '.json']);
            temporary = [target '.tmp'];
            fid = fopen(temporary,'w','n','UTF-8');
            if fid<0, error('MatlabAI:HistoryWrite','无法保存本地对话，当前内容仍保留在窗口内。'); end
            cleanup = onCleanup(@() fclose(fid));
            fwrite(fid,unicode2native(jsonencode(data),'UTF-8'),'uint8');
            clear cleanup;
            [ok,message] = movefile(temporary,target,'f');
            if ~ok, error('MatlabAI:HistoryWrite','无法保存本地对话：%s',message); end
        end

        function load(obj,id)
            if isempty(regexp(id,'^[a-fA-F0-9-]{36}$','once')) || isempty(obj.Folder)
                error('MatlabAI:HistoryID','无效的对话编号。');
            end
            file = fullfile(obj.Folder,[id '.json']);
            info = dir(file);
            if isempty(info) || info.bytes > 100000000
                error('MatlabAI:HistoryFile','对话文件不存在或过大。');
            end
            try
                data = jsondecode(fileread(file));
                assert(data.version==1 && strcmp(data.id,id) && isstruct(data.turns));
                fields = {'question','mode','model','explanation','replacement','time'};
                assert(all(isfield(data.turns,fields)));
                for k=1:numel(data.turns)
                    for f=1:numel(fields)
                        value = data.turns(k).(fields{f});
                        assert(ischar(value) && (isrow(value) || isempty(value)));
                    end
                    assert(ismember(data.turns(k).mode,{'generate','edit','explain','complete','help','sim_explain','sim_edit','sim_function'}));
                    assert(numel(data.turns(k).replacement)<=300000);
                end
            catch
                error('MatlabAI:HistoryFile','历史文件无法读取，原文件已保留。');
            end
            obj.ID = id;
            obj.Turns = orderfields(data.turns(:)',obj.Turns);
            obj.Owned = false;
        end

        function branch(obj,index)
            if index<1 || index>numel(obj.Turns), error('MatlabAI:HistoryIndex','请选择一个历史版本。'); end
            obj.Turns = obj.Turns(1:index);
            obj.Owned = false;
        end

        function entries = list(obj)
            entries = struct('id',{},'label',{});
            if isempty(obj.Folder), return; end
            files = dir(fullfile(obj.Folder,'*.json'));
            [~,order] = sort([files.datenum],'descend');
            for k=order
                [~,id] = fileparts(files(k).name);
                if isempty(regexp(id,'^[a-fA-F0-9-]{36}$','once')), continue; end
                try
                    data = jsondecode(fileread(fullfile(obj.Folder,files(k).name)));
                    title = regexprep(data.turns(1).question,'\s+',' ');
                    title = title(1:min(35,numel(title)));
                    entries(end+1) = struct('id',id,'label',sprintf('%s · %s (%d轮)', ...
                        data.turns(end).time,title,numel(data.turns)));
                catch
                    % Corrupt files are preserved, never silently overwritten.
                end
            end
        end

        function history = context(obj,helpOnly)
            % Keep the latest complete turns, bounded by both count and size.
            history = {};
            if nargin<2, helpOnly=false; end
            total = 0;
            for k=numel(obj.Turns):-1:max(1,numel(obj.Turns)-5)
                turn = rmfield(obj.Turns(k),{'model','time'});
                if helpOnly && ~strcmp(turn.mode,'help'), continue; end
                cost = numel(turn.question)+numel(turn.mode)+numel(turn.explanation)+numel(turn.replacement);
                if total+cost>600000, break; end
                total = total+cost;
                history = [{turn},history];
            end
        end
    end
end
