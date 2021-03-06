
function [t_mean, t_processed] = Merge_CellCountData(t_annotated, plate_inkeys, ...
    cond_inkeys, plate_reps, numericfields)
% [t_mean, t_processed] = Merge_CellCountData(t_annotated, plate_inkeys, cond_inkeys, 
%                               plate_reps, numericfields)
%
%   process the data from cell count. The data will be split for controls according
%   to plate_keys (with 'CellLine' 'TreatmentFile' 'Time' as mandatory and
%   default) and for merging according to cond_keys (with 'Conc' 'DrugName'
%   as default).
%   Needs also the columns 'Untrt' (for Day0 or control plate), 'pert_type' (looking for value
%   'ctl_vehicle' or 'trt_cp'/'trt_poscon') and 'DesignNumber' (serves as
%   replicates/ plate number)
%   Set 'plate_reps' as true if there are replicates on the same plates
%   (this will bypass the check in creating t_mean).
%
%   outputs are:    t_processed with the values for all treated wells
%                   t_mean where replicates are averaged
%
fprintf('Merge the cell count data, normalize by controls:\n');

%% assign and control the variables
if exist('plate_inkeys','var') && ~isempty(plate_inkeys)
    plate_keys = unique([{'CellLine' 'Time'} plate_inkeys]);
else
    plate_keys = {'CellLine' 'Time'};
    plate_inkeys = {};
end
if exist('cond_inkeys','var') && ~isempty(cond_inkeys)
    cond_keys = unique([{'DrugName' 'Conc'} cond_inkeys]);
else
    cond_keys = {'DrugName' 'Conc'};
end
if ~exist('plate_reps','var') || isempty(plate_reps)
    plate_reps = false;
end

cond_keys = [cond_keys ...
    intersect(varnames(t_annotated), strcat('DrugName', cellfun(@(x) {num2str(x)}, num2cell(2:9)))) ...
    intersect(varnames(t_annotated), strcat('Conc', cellfun(@(x) {num2str(x)}, num2cell(2:9))))];

assert(all(ismember([plate_keys cond_keys 'pert_type'], t_annotated.Properties.VariableNames)),...
    'Column(s) [ %s ] missing from t_data', strjoin(setdiff([plate_keys cond_keys 'pert_type'], ...
    unique(t_annotated.Properties.VariableNames)),' '))

% decide if growth inhibition can be calculated (need untreated & time=0)
EvaluateGI = any(t_annotated.Untrt & t_annotated.Time==0);


labelfields = {'pert_type' 'RelCellCnt' 'RelGrowth' 'DesignNumber' 'Barcode' ...
    'Untrt' 'Cellcount' 'Date' 'Row' 'Column' 'Well' 'TreatmentFile' 'Replicate'};
if ~exist('numericfields','var')
    numericfields = setdiff(t_annotated.Properties.VariableNames( ...
        all(cellfun(@isnumeric, table2cell(t_annotated)))), [plate_keys cond_keys labelfields]);
    if ~isempty(numericfields)
        fprintf('\tThese numeric fields will be averaged (set as cond_inkeys to use them as key):\n');
        for i=1:length(numericfields)
            fprintf('\t - %s\n', numericfields{i});
        end
    end
end
%%

% find the number of different of plates to merge and group them based on
% the plate_keys (with Time==0)
t_plate = unique(t_annotated(:,plate_keys));
t_plate = t_plate(t_plate.Time~=0,:);

t_processed = table;
t_mean = table;

% loop through the different plates
for iP = 1:height(t_plate)
    %
    % find the cell count at day 0
    if EvaluateGI
        temp = t_plate(iP,setdiff(plate_keys, {'TreatmentFile'}, 'stable'));
        temp.Time = 0;
        Day0Cnt = trimmean( t_annotated.Cellcount(eqtable(temp, ...
            t_annotated(:,setdiff(plate_keys, {'TreatmentFile'}, 'stable')))), 50);
        Relvars = {'RelCellCnt' 'RelGrowth'};
    else
        Day0Cnt = NaN;
        Relvars = {'RelCellCnt'};
    end
    
    t_conditions = t_annotated(eqtable(t_plate(iP,:), t_annotated(:,plate_keys)) , :);
    
    % found the control for treated plates (ctl_vehicle)
    t_ctrl = t_conditions(t_conditions.pert_type=='ctl_vehicle',:);
    assert(height(t_ctrl)>0, 'No control found for %s --> check ''pert_type''', ...
        strjoin(strcat(table2cellstr( t_plate(iP,:), 0)), '|'))
    
    t_ctrl = collapse(t_ctrl, @(x) trimmean(x,50), 'keyvars', ...
        {'DesignNumber'}, 'valvars', [{'Cellcount'} numericfields]);
    t_ctrl.Properties.VariableNames{'Cellcount'} = 'Ctrlcount';
    for i=1:length(numericfields)
        t_ctrl.Properties.VariableNames{numericfields{i}} = ['Ctrl_' numericfields{i}];
    end
    t_ctrl = [t_ctrl table(repmat(Day0Cnt, height(t_ctrl),1), 'VariableNames', {'Day0Cnt'})];
    
    % report the ctrl values in the table
    t_conditions = innerjoin(t_conditions(ismember(t_conditions.pert_type, ...
        {'trt_cp' 'trt_poscon'}),:), t_ctrl);
    % evaluate the relative cell count/growth
    t_conditions = [t_conditions array2table([t_conditions.Cellcount./t_conditions.Ctrlcount ...
        (t_conditions.Cellcount-t_conditions.Day0Cnt)./(t_conditions.Ctrlcount-t_conditions.Day0Cnt)], ...
        'variablenames', {'RelCellCnt' 'RelGrowth'})];
    
    
    if ~EvaluateGI
        t_conditions.RelGrowth = [];
        t_conditions.Day0Cnt = [];
    end
    
    t_processed = [t_processed; t_conditions];
    
    
    %%%%%%%%% maybe move that part out of the loop if there are
    %%%%%%%%% corresponding replicates from different plates
    
    % collapse the replicates
    temp = collapse(t_conditions, @mean, 'keyvars', [plate_keys cond_keys], ...
        'valvars', [Relvars {'Cellcount' 'Ctrlcount'} numericfields strcat('Ctrl_', numericfields)]);
    ht = height(temp);
    
    temp2 = unique(t_conditions(:, setdiff(varnames(t_conditions), ...
        [strcat('Ctrl_', numericfields) labelfields numericfields {'Ctrlcount'}])),'stable');
    temp = innerjoin(temp, temp2, 'keys', [setdiff(plate_keys, plate_inkeys) cond_keys ], ...
        'rightvariables', setdiff(varnames(temp2), varnames(temp)));
    
    assert(height(temp)<=ht, 'merging failed; need to debug')
    assert(plate_reps || height(temp)==ht, ['Some replicates have been merged accidentally,' ...
        ' this may be due to replicate on the same plate (set plate_reps=true), or use ''cond_inkeys'''])
    t_mean = [t_mean; temp];
end


t_mean = sortrows(t_mean, [plate_keys cond_keys]);

end
