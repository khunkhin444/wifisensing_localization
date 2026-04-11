function csi_build_windows(varargin)
% Build clean CSI windows (amplitude + phase) from one or more PicoScenes .csi files.
%
% Exports per-window .npy tensors and .mat metadata.
% Metadata includes receiver-aware fields for domain-safe downstream splits:
%   receiver_domain, session_id, anchor_label, source_file, window_index
%
% Exports:
%   <out>/<basename>/
%       amp_window_00001.npy      % [T_win x S_kept x A], float32
%       ampn_window_00001.npy     % normalized amplitude, float32
%       pha_window_00001.npy      % [T_win x S_kept x A], float32
%       meta_00001.mat
%
% PASSIVE VERSION:
% 1) packet-count windowing only
% 2) no timestamp-based fs required
% 3) amplitude-first export
% 4) phase optional
% 5) keep low-quality windows by default
% 6) export extra metadata for later KDE/JS confidence weighting
%
% REQUIRE: parseCSIFile.m on MATLAB path
%
% Example:
% csi_build_windows( ...
%   'TargetCF',5805, 'TargetCBW',20, ...
%   'WinPkts',800, 'HopPkts',400, ...
%   'HampelK',3, 'SG_FramePkts',31, ...
%   'PhaseSG_FramePkts',31, ...
%   'TrimEdges',[6 6], ...
%   'NumSubStats',5, ...
%   'KeepRejectedWindows',true, ...
%   'Verbose',true);

%% ---------------- Params ----------------
p = inputParser;

% output
addParameter(p,'OutDir','', @ischar);

% carrier filter
addParameter(p,'UseCF_CBW_Filter',true, @islogical);
addParameter(p,'TargetCF',5805, @(x) isempty(x) || isscalar(x)); % MHz; [] to skip
addParameter(p,'CFTol',15, @isscalar);
addParameter(p,'TargetCBW',20, @isscalar);                       % MHz

% packet windowing
addParameter(p,'WinPkts',256, @isscalar);
addParameter(p,'HopPkts',64, @isscalar);
addParameter(p,'MinFillRatio',0.85, @isscalar);

% cleaning
addParameter(p,'HampelK',3, @isscalar);
addParameter(p,'SG_Poly',2, @isscalar);
addParameter(p,'SG_FramePkts',21, @isscalar);         % amplitude SG length in packets
addParameter(p,'PhaseSG_FramePkts',21, @isscalar);    % phase SG length in packets
addParameter(p,'UseAmplitudeClip',false, @islogical);
addParameter(p,'ClipMADMult',6, @isscalar);

% subcarriers
addParameter(p,'TrimEdges',[6 6], @(x)isnumeric(x)&&numel(x)==2);
addParameter(p,'SubsampleStep',1, @isscalar);

% normalization
addParameter(p,'SaveNormalizedAmp',true, @islogical);

% quality score
addParameter(p,'MinWinScore',0.12, @isscalar);
addParameter(p,'MinAmpScore',0.006, @isscalar);
addParameter(p,'SaveWindowScore',true, @islogical);

% export stats for KDE/JS confidence
addParameter(p,'NumSubStats',5, @isscalar);
addParameter(p,'SavePhase',true, @islogical);
addParameter(p,'KeepRejectedWindows',true, @islogical);

% misc
addParameter(p,'Verbose',true, @islogical);

%AveCSI
addParameter(p,'UseAveCSI',true, @islogical);
addParameter(p,'AveCSIMode','both', @(x)ischar(x) || isstring(x));
% 'none'  : do not use AveCSI
% 'avg'   : export averaged amplitude only
% 'both'  : export raw window + averaged amplitude
% 'stack' : export raw window concatenated with broadcasted average

parse(p,varargin{:});
opt = p.Results;

%% ---------------- Multi-file select ----------------
[files, pathname] = uigetfile('*.csi', 'Select CSI file(s)', 'MultiSelect','on');
if isequal(files,0)
    disp('User canceled.');
    return;
end
if ischar(files)
    files = {files};
end

fprintf('Selected %d file(s)\n', numel(files));

for fi = 1:numel(files)
    filename = files{fi};
    fullpath = fullfile(pathname, filename);
    [~, base, ~] = fileparts(filename);

    fprintf('\n============================================================\n');
    fprintf('[%d/%d] Processing: %s\n', fi, numel(files), filename);
    fprintf('============================================================\n');

    outDir = opt.OutDir;
    if isempty(outDir)
        fileOutDir = fullfile(pathname, base);
    else
        fileOutDir = fullfile(outDir, base);
    end
    if ~exist(fileOutDir,'dir'), mkdir(fileOutDir); end

    winDir = fileOutDir;
    if ~exist(winDir,'dir'), mkdir(winDir); end

    try
        process_one_file(fullpath, base, winDir, opt);
    catch ME
        warning('Failed on %s\n%s', filename, getReport(ME, 'extended', 'hyperlinks','off'));
    end
end

fprintf('\n[✓] All done.\n');

end % ===== main =====


%% ========================================================================
function process_one_file(fullpath, base, winDir, opt)

fprintf('Start parsing PicoScenes CSI file: %s\n', fullpath);
S = parseCSIFile(fullpath);
N = numel(S);
if opt.Verbose
    fprintf('[seg] segments: %d\n', N);
end

%% -------- Collect frames: amplitude & phase, CF/CBW, timestamps --------
A_rows = {};   % each cell [A x S]
P_rows = {};   % each cell [A x S]
t_rows = [];
cf_rows = [];
bw_rows = [];
nsc_rows = [];
rx_rows = [];

% Try bundled block first
is_bundled_handled = false;
if N >= 1 && isstruct(S{1}) && isfield(S{1},'CSI')
    C1 = S{1}.CSI;
    if isfield(C1,'Mag') && ~isempty(C1.Mag) && isnumeric(C1.Mag) && ismatrix(C1.Mag)
        M = double(C1.Mag);
        if size(M,1) > 100 && size(M,2) > 20
            T_bundle = size(M,1);
            Ccols = size(M,2);

            P = [];
            if isfield(C1,'Phase') && ~isempty(C1.Phase)
                Ptmp = double(C1.Phase);
                if isequal(size(Ptmp), size(M))
                    P = Ptmp;
                end
            end

            NSC_SET = [52 53 56 114 122 234 242];
            best = [];
            bestErr = inf;

            for sGuess = NSC_SET
                aGuess = round(Ccols / sGuess);
                if aGuess >= 1 && aGuess <= 8
                    err = abs(Ccols - sGuess*aGuess);
                    if err < bestErr
                        best = [sGuess aGuess];
                        bestErr = err;
                    end
                end
            end

            if isempty(best)
                for aGuess = 1:8
                    if mod(Ccols, aGuess) == 0
                        sGuess = Ccols / aGuess;
                        best = [sGuess aGuess];
                        bestErr = 0;
                        break;
                    end
                end
            end

            if ~isempty(best)
                S_target = best(1);
                A_target = best(2);

                for i = 1:T_bundle
                    rowM = M(i,1:(S_target*A_target));
                    R = reshape(rowM, [S_target, A_target]).';  % [A x S]
                    A_rows{end+1,1} = R; %#ok<AGROW>

                    if ~isempty(P)
                        rowP = P(i,1:(S_target*A_target));
                        Rph = reshape(rowP, [S_target, A_target]).';
                        P_rows{end+1,1} = Rph;
                    else
                        P_rows{end+1,1} = nan(A_target,S_target);
                    end

                    t_rows(end+1,1) = get_ts_one(C1, i); %#ok<AGROW>
                    [cfMHz, cbwMHz] = get_cf_cbw(C1, i);
                    cf_rows(end+1,1) = cfMHz; %#ok<AGROW>
                    bw_rows(end+1,1) = cbwMHz; %#ok<AGROW>
                    nsc_rows(end+1,1) = S_target; %#ok<AGROW>
                    rx_rows(end+1,1) = A_target; %#ok<AGROW>
                end
                is_bundled_handled = true;
            end
        end
    end
end

% Fallback to per-segment extraction
if ~is_bundled_handled
    for k = 1:N
        Sk = S{k};
        if ~isstruct(Sk) || ~isfield(Sk,'CSI')
            continue;
        end
        C = Sk.CSI;

        Z = [];
        if isfield(C,'csi')
            Z = double(C.csi);
        end

        Mag = [];
        Pha = [];
        if isfield(C,'Mag'),   Mag = double(C.Mag);   end
        if isfield(C,'Phase'), Pha = double(C.Phase); end

        if isempty(Z) && isempty(Mag)
            continue;
        end

        if ~isempty(Z)
            Z = squeeze(Z);
            if ndims(Z)==3
                Z = reshape(Z, size(Z,1), []);
            end
            if size(Z,1) < size(Z,2)
                Z = Z.';
            end
            amp = abs(Z);
            pha = angle(Z);
        else
            M = squeeze(Mag);
            if size(M,1) < size(M,2)
                M = M.';
            end
            amp = M;

            if ~isempty(Pha)
                P = squeeze(Pha);
                if size(P,1) < size(P,2)
                    P = P.';
                end
                pha = P;
            else
                pha = nan(size(amp));
            end
        end

        nTones = size(amp,1);
        nRx    = size(amp,2);
        if nTones==0 || nRx==0
            continue;
        end

        t_rows(end+1,1) = get_ts_one(C,1); %#ok<AGROW>
        [cfMHz, cbwMHz] = get_cf_cbw(C,1);
        cf_rows(end+1,1) = cfMHz; %#ok<AGROW>
        bw_rows(end+1,1) = cbwMHz; %#ok<AGROW>

        A_rows{end+1,1} = amp.'; %#ok<AGROW>   % [A x S]
        P_rows{end+1,1} = pha.'; %#ok<AGROW>   % [A x S]
        nsc_rows(end+1,1) = nTones; %#ok<AGROW>
        rx_rows(end+1,1)  = nRx; %#ok<AGROW>
    end
end

assert(~isempty(A_rows), 'No CSI frames found.');

%% -------- CF/CBW filter --------
keep = true(size(A_rows));
if opt.UseCF_CBW_Filter
    if isempty(opt.TargetCF)
        cf_ok = true(size(cf_rows));
    else
        cf_ok = isnan(cf_rows) | (abs(cf_rows - opt.TargetCF) <= opt.CFTol);
    end
    bw_ok = isnan(bw_rows) | (bw_rows == opt.TargetCBW);
    keep = cf_ok & bw_ok;

    if ~any(keep)
        warning('No frames survive requested CF/CBW filter. Keeping CBW only.');
        keep = (isnan(bw_rows) | (bw_rows == opt.TargetCBW));
    end
end

A_rows = A_rows(keep);
P_rows = P_rows(keep);
t_rows = t_rows(keep);
cf_rows = cf_rows(keep);
bw_rows = bw_rows(keep);
nsc_rows = nsc_rows(keep);
rx_rows = rx_rows(keep);

%% -------- Harmonize shape by majority --------
S_target = mode(nsc_rows);
A_target = mode(rx_rows);
sel = (nsc_rows == S_target) & (rx_rows == A_target);

A_rows = A_rows(sel);
P_rows = P_rows(sel);
t_rows = t_rows(sel);
cf_rows = cf_rows(sel);
bw_rows = bw_rows(sel);

T = numel(A_rows);
ucf = unique(round(cf_rows(~isnan(cf_rows))));
ucbw = unique(bw_rows(~isnan(bw_rows)));

if opt.Verbose
    fprintf('[shape] T=%d, S=%d, A=%d | CF≈%s MHz | CBW=%s MHz\n', ...
        T, S_target, A_target, mat2str(ucf.'), mat2str(ucbw.'));
end

%% -------- Stack to tensors [T x S x A] --------
Amp = zeros(T, S_target, A_target, 'double');
Pha = zeros(T, S_target, A_target, 'double');
Pha(:) = NaN;

for i = 1:T
    Ra = A_rows{i};
    Rp = P_rows{i};

    if size(Ra,2) > S_target, Ra = Ra(:,1:S_target); end
    if size(Rp,2) > S_target, Rp = Rp(:,1:S_target); end

    Amp(i,:,:) = permute(Ra, [2 1]); % [S x A]
    Pha(i,:,:) = permute(Rp, [2 1]);
end

%% -------- Packet-window plan --------
win  = max(4, round(opt.WinPkts));
hop  = max(1, round(opt.HopPkts));
need = max(1, floor(opt.MinFillRatio * win));

starts = 1:hop:(T - win + 1);
stops  = starts + win - 1;

if opt.Verbose
    fprintf('[win] win=%d pkts, hop=%d pkts, min=%d, candidates=%d\n', ...
        win, hop, need, numel(starts));
end

%% -------- Subcarrier keep-set --------
L = max(0, min(opt.TrimEdges(1), S_target-1));
R = max(0, min(opt.TrimEdges(2), S_target-1-L));

if (1+L) > (S_target-R)
    L = 0; R = 0;
    warning('TrimEdges too strong; reset to [0 0].');
end

keep_idx = (1+L):(S_target-R);
if opt.SubsampleStep > 1
    keep_idx = keep_idx(1:opt.SubsampleStep:end);
end
if isempty(keep_idx)
    keep_idx = 1:S_target;
end
S_kept = numel(keep_idx);

if opt.Verbose
    fprintf('[keep] S_raw=%d -> keep=%d (Trim=[%d %d], step=%d)\n', ...
        S_target, S_kept, L, R, opt.SubsampleStep);
end

%% -------- Helpers for phase detrending --------
S_idx = (1:S_target)';

    function row = detrend_phase_row(row_in)
        row_unw = unwrap(row_in);
        X = [S_idx ones(size(S_idx))];
        ab = X \ row_unw(:);
        row = row_unw(:).' - (ab(1)*S_idx + ab(2)).';
    end

ampFrameLen   = make_odd_len(opt.SG_FramePkts);
phaseFrameLen = make_odd_len(opt.PhaseSG_FramePkts);

%% -------- Export per window --------
exported = 0;
flagged_bad = 0;

for w = 1:numel(starts)
    idx = starts(w):stops(w);
    if numel(idx) < need
        continue;
    end

    Aw = Amp(idx,:,:);   % [Tw x S x A]
    Pw = Pha(idx,:,:);
    Tw = size(Aw,1);

    % ----- amplitude cleaning -----
    for a = 1:A_target
        for s = 1:S_target
            Aw(:,s,a) = clean_amp_series(Aw(:,s,a), opt.HampelK, opt.SG_Poly, ampFrameLen);
        end
    end

    % optional robust clipping
    if opt.UseAmplitudeClip
        for a = 1:A_target
            for s = 1:S_target
                xs = Aw(:,s,a);
                medv = median(xs);
                madv = median(abs(xs - medv)) + eps;
                hi = medv + opt.ClipMADMult * madv;
                Aw(:,s,a) = min(xs, hi);
            end
        end
    end

    % ----- phase cleaning -----
    if all(isnan(Pw(:)))
        Pw = zeros(size(Pw), 'like', Aw);
    else
        for t1 = 1:Tw
            for a = 1:A_target
                row = squeeze(Pw(t1,:,a));
                if any(isfinite(row))
                    row(~isfinite(row)) = 0;
                    Pw(t1,:,a) = detrend_phase_row(row);
                else
                    Pw(t1,:,a) = 0;
                end
            end
        end

        for a = 1:A_target
            for s = 1:S_target
                Pw(:,s,a) = sgolay_safely(Pw(:,s,a), 3, phaseFrameLen);
            end
        end
    end

    % ----- keep subcarriers -----
    Aw = Aw(:, keep_idx, :);
    Pw = Pw(:, keep_idx, :);
    
    % ----- AveCSI -----
    % For passive sparse traffic, average within the current packet window.
    % Output shapes:
    %   Aw_avg       : [1  x S_kept x A]
    %   Aw_avg_tile  : [Tw x S_kept x A]  (broadcasted AveCSI)
    if opt.UseAveCSI
        Aw_avg = mean(Aw, 1, 'omitnan');
        Aw_avg_tile = repmat(Aw_avg, [size(Aw,1), 1, 1]);
    else
        Aw_avg = [];
        Aw_avg_tile = [];
    end
    
    % ----- choose export tensor -----
    Aw_export = Aw;  % default raw amplitude window
    
    mode_str = lower(string(opt.AveCSIMode));
    if opt.UseAveCSI
        switch mode_str
            case "avg"
                % export only the average CSI frame
                Aw_export = Aw_avg;                 % [1 x S x A]
    
            case "both"
                % keep raw export as main input, save avg separately below
                Aw_export = Aw;                     % [Tw x S x A]
    
            case "stack"
                % concatenate raw + AveCSI as channel-expanded tensor
                % result: [Tw x S x (2A)]
                Aw_export = cat(3, Aw, Aw_avg_tile);
    
            otherwise
                % 'none' or unknown -> raw only
                Aw_export = Aw;
        end
    end
    
    % ----- normalized amplitude -----
    if opt.SaveNormalizedAmp
        mu = mean(Aw_export, 1, 'omitnan');
        sd = std(Aw_export, 0, 1, 'omitnan') + 1e-6;
        Awn = (Aw_export - mu) ./ sd;
    else
        Awn = [];
    end
    % ----- normalized amplitude -----
    if opt.SaveNormalizedAmp
        mu = mean(Aw, 1, 'omitnan');
        sd = std(Aw, 0, 1, 'omitnan') + 1e-6;
        Awn = (Aw - mu) ./ sd;
    else
        Awn = [];
    end

    % ----- window quality -----
    q = score_window(Aw, Pw);
    is_bad_window = (q.amp_score < opt.MinAmpScore || q.total < opt.MinWinScore);

    if is_bad_window
        flagged_bad = flagged_bad + 1;
        if ~opt.KeepRejectedWindows
            continue;
        end
    end

    % ----- export scalar stats for KDE/JS confidence -----
    z = compute_window_stats(Aw, Awn, Pw, opt.NumSubStats);

    exported = exported + 1;

    write_npy(fullfile(winDir, sprintf('amp_window_%05d.npy', exported)), single(Aw_export));
    
    if opt.SaveNormalizedAmp
        write_npy(fullfile(winDir, sprintf('ampn_window_%05d.npy', exported)), single(Awn));
    end
    
    % save AveCSI separately when requested
    if opt.UseAveCSI && (mode_str == "both" || mode_str == "avg")
        write_npy(fullfile(winDir, sprintf('ampavg_window_%05d.npy', exported)), single(Aw_avg));
    end
    
    if opt.UseAveCSI && mode_str == "both"
        write_npy(fullfile(winDir, sprintf('ampavg_tile_window_%05d.npy', exported)), single(Aw_avg_tile));
    end

    if opt.SavePhase
        write_npy(fullfile(winDir, sprintf('pha_window_%05d.npy', exported)), single(Pw));
    end

    meta = struct();
    meta.session_id   = infer_session_id(base, fullpath);
    meta.window_index = exported;
    meta.source_file  = fullpath;
    meta.receiver_domain = infer_receiver_domain(fullpath, base);
    meta.anchor_label = infer_anchor_label(fullpath, base);

    % packet-based indexing
    meta.pkt_start_idx = idx(1);
    meta.pkt_end_idx   = idx(end);
    meta.window_pkt_count = Tw;
    meta.WinPkts       = opt.WinPkts;
    meta.HopPkts       = opt.HopPkts;
    meta.MinFillRatio  = opt.MinFillRatio;

    % optional timestamps if available
    if ~isempty(t_rows) && numel(t_rows) >= idx(end)
        meta.t0 = t_rows(idx(1));
        meta.t1 = t_rows(idx(end));
    else
        meta.t0 = NaN;
        meta.t1 = NaN;
    end

    meta.CF_MHz       = round(nanmedian(cf_rows));
    meta.CBW_MHz      = nanmedian(bw_rows);

    meta.S_raw        = S_target;
    meta.S_kept       = S_kept;
    meta.A_rx         = A_target;
    meta.keep_idx     = keep_idx;
    meta.TrimEdges    = [L R];
    meta.Step         = opt.SubsampleStep;

    meta.packet_count = Tw;
    meta.fill_ratio   = Tw / win;
    meta.nominal_win_packets = win;

    % raw statistics for Python KDE confidence
    meta.amp_mean     = z.amp_mean;
    meta.amp_std      = z.amp_std;
    meta.amp_var      = z.amp_var;
    meta.amp_range    = z.amp_range;
    meta.amp_energy   = z.amp_energy;
    meta.ampn_std     = z.ampn_std;
    meta.phase_std    = z.phase_std;

    % sub-window statistics
    meta.z_sub_amp_std   = z.z_sub_amp_std;
    meta.z_sub_ampn_std  = z.z_sub_ampn_std;
    meta.z_sub_energy    = z.z_sub_energy;
    meta.NumSubStats     = opt.NumSubStats;
    meta.UseAveCSI   = opt.UseAveCSI;
    meta.AveCSIMode  = char(mode_str);
    
    if opt.UseAveCSI
        meta.ampavg_mean   = mean(Aw_avg(:), 'omitnan');
        meta.ampavg_std    = std(Aw_avg(:), 0, 'omitnan');
        meta.ampavg_energy = mean(Aw_avg(:).^2, 'omitnan');
    else
        meta.ampavg_mean   = NaN;
        meta.ampavg_std    = NaN;
        meta.ampavg_energy = NaN;
    end
    meta.is_flagged_bad = is_bad_window;

    if opt.SaveWindowScore
        meta.win_score  = q.total;
        meta.amp_score  = q.amp_score;
        meta.pha_score  = q.pha_score;
        meta.corr_score = q.corr_score;
    end

    save(fullfile(winDir, sprintf('meta_%05d.mat', exported)), 'meta');

    if opt.Verbose && mod(exported, 200) == 0
        fprintf('  exported %d...\n', exported);
    end
end

fprintf('[✓] Done: exported=%d, flagged_bad=%d, out=%s\n', exported, flagged_bad, winDir);

end


%% ========================================================================
function z = compute_window_stats(Aw, Awn, Pw, numSub)

Tw = size(Aw,1);

tmp = std(Aw, 0, 1, 'omitnan');
z.amp_mean   = mean(Aw(:), 'omitnan');
z.amp_std    = median(tmp(:), 'omitnan');
z.amp_var    = var(Aw(:), 0, 'omitnan');
z.amp_range  = max(Aw(:)) - min(Aw(:));
z.amp_energy = mean(Aw(:).^2, 'omitnan');

if ~isempty(Awn)
    tmp = std(Awn, 0, 1, 'omitnan');
    z.ampn_std = median(tmp(:), 'omitnan');
else
    z.ampn_std = NaN;
end

if isempty(Pw) || all(~isfinite(Pw(:)))
    z.phase_std = NaN;
else
    tmp = std(Pw, 0, 1, 'omitnan');
    z.phase_std = median(tmp(:), 'omitnan');
end

numSub = max(1, round(numSub));
sub_edges = round(linspace(1, Tw+1, numSub+1));

z.z_sub_amp_std  = nan(numSub,1);
z.z_sub_ampn_std = nan(numSub,1);
z.z_sub_energy   = nan(numSub,1);

for i = 1:numSub
    s1 = sub_edges(i);
    s2 = sub_edges(i+1) - 1;
    if s2 < s1
        continue;
    end

    subA = Aw(s1:s2,:,:);

    tmp = std(subA, 0, 1, 'omitnan');
    z.z_sub_amp_std(i) = median(tmp(:), 'omitnan');

    z.z_sub_energy(i) = mean(subA(:).^2, 'omitnan');

    if ~isempty(Awn)
        subAn = Awn(s1:s2,:,:);
        tmp = std(subAn, 0, 1, 'omitnan');
        z.z_sub_ampn_std(i) = median(tmp(:), 'omitnan');
    end
end
end


%% ========================================================================
function ts = get_ts_one(C, i)
ts = NaN;
if isfield(C,'Timestamp')
    v = double(C.Timestamp);
    if ~isempty(v), ts = v(min(i, numel(v))); end
elseif isfield(C,'TimingOffsets')
    v = double(C.TimingOffsets);
    if ~isempty(v), ts = v(min(i, numel(v))); end
end
end


%% ========================================================================
function [cfMHz, cbwMHz] = get_cf_cbw(C, i)
cfMHz = NaN;
cbwMHz = NaN;

if isfield(C,'CarrierFreq')
    v = double(C.CarrierFreq);
    if ~isempty(v), cfMHz = v(min(i,end)); end
elseif isfield(C,'cf')
    v = double(C.cf);
    if ~isempty(v), cfMHz = v(min(i,end)); end
end

if isfinite(cfMHz)
    if cfMHz > 1e6
        cfMHz = cfMHz/1e6;
    elseif cfMHz > 1e3
        cfMHz = cfMHz/1e3;
    end
end

if isfield(C,'CBW')
    v = double(C.CBW);
    if ~isempty(v), cbwMHz = v(min(i,end)); end
elseif isfield(C,'Pkt_CBW')
    v = double(C.Pkt_CBW);
    if ~isempty(v), cbwMHz = v(min(i,end)); end
elseif isfield(C,'cbw')
    v = double(C.cbw);
    if ~isempty(v), cbwMHz = v(min(i,end)); end
end
end


%% ========================================================================
function y = sgolay_safely(x, p, framelen)
framelen = make_odd_len(framelen);
try
    y = sgolayfilt(x, p, framelen);
catch
    y = movmedian(x, max(3, round(framelen/4)));
    y = movmean(y,   max(3, round(framelen/4)));
end
end


%% ========================================================================
function n = make_odd_len(n)
n = max(5, round(n));
if mod(n,2)==0
    n = n + 1;
end
end


%% ========================================================================
function x = clean_amp_series(x, k, sg_p, sg_len)
if isempty(k) || k < 1
    k = 3;
end

try
    x = hampel(x, k);
catch
    n = numel(x);
    y = x;
    for i = 1:n
        i1 = max(1,i-k);
        i2 = min(n,i+k);
        win = x(i1:i2);
        med = median(win);
        madv = median(abs(win-med)) + eps;
        if abs(x(i)-med) > 4*madv
            y(i) = med;
        end
    end
    x = y;
end

if sg_len >= 5
    x = sgolay_safely(x, sg_p, sg_len);
end
end


%% ========================================================================
function q = score_window(Aw, Pw)
% Aw, Pw: [Tw x S x A]

a_std = std(Aw, 0, 1, 'omitnan');
amp_score = median(a_std(:), 'omitnan');

p_std = std(Pw, 0, 1, 'omitnan');
pha_score = 1 / (median(p_std(:), 'omitnan') + eps);

Tw = size(Aw,1);
X = reshape(Aw, Tw, []);
if size(X,2) >= 2
    try
        C = corrcoef(X, 'Rows','pairwise');
        mask = triu(true(size(C)),1);
        vals = C(mask);
        vals = vals(isfinite(vals));
        if isempty(vals)
            corr_score = 0;
        else
            corr_score = median(vals);
        end
    catch
        corr_score = 0;
    end
else
    corr_score = 0;
end

q.amp_score  = amp_score;
q.pha_score  = pha_score;
q.corr_score = corr_score;

q.total = 0.5 * squash_scalar(amp_score) + ...
          0.2 * squash_scalar(pha_score) + ...
          0.3 * squash_scalar(corr_score);
end


%% ========================================================================
function y = squash_scalar(x)
if ~isfinite(x)
    y = 0;
else
    y = x / (abs(x) + 1);
end
end


%% ========================================================================
function write_npy(fname, A)
if ~isreal(A)
    error('write_npy: complex not supported; split amp/phase first.');
end
if islogical(A)
    A = uint8(A);
end

switch class(A)
    case 'double', descr = '<f8';
    case 'single', descr = '<f4';
    case 'uint8',  descr = '|u1';
    case 'int8',   descr = '|i1';
    case 'uint16', descr = '<u2';
    case 'int16',  descr = '<i2';
    case 'uint32', descr = '<u4';
    case 'int32',  descr = '<i4';
    case 'uint64', descr = '<u8';
    case 'int64',  descr = '<i8';
    otherwise
        error('write_npy: unsupported class %s', class(A));
end

sz = size(A);
shapeStr = sprintf('(%s)', strjoin(string(sz), ','));
hdr = sprintf('{''descr'': ''%s'', ''fortran_order'': True, ''shape'': %s }', descr, shapeStr);

magic = uint8([147,'NUMPY']);
ver = uint8([1 0]);
h = uint8(hdr);
pad = 16 - mod(numel(magic)+2+2+numel(h), 16);
if pad == 0, pad = 16; end
h = [h, uint8(repmat(' ',1,pad-1)), uint8(sprintf('\n'))];

fid = fopen(fname,'w');
assert(fid > 0, 'Cannot open %s', fname);

fwrite(fid, magic, 'uint8');
fwrite(fid, ver, 'uint8');
fwrite(fid, uint16(numel(h)), 'uint16', 0, 'ieee-le');
fwrite(fid, h, 'uint8');
fwrite(fid, A, class(A), 0, 'ieee-le');
fclose(fid);
end


%% ========================================================================
function dom = infer_receiver_domain(fullpath, base)
dom = "unknown";
tokens = [string(fullpath), string(base)];
for i = 1:numel(tokens)
    t = lower(tokens(i));
    if contains(t, filesep + "a" + filesep) || ~isempty(regexp(t, '(^|[_\-])a([_\-]|$)', 'once'))
        dom = "A";
        return;
    end
    if contains(t, filesep + "b" + filesep) || ~isempty(regexp(t, '(^|[_\-])b([_\-]|$)', 'once'))
        dom = "B";
        return;
    end
    hit = regexp(t, 'receiver[_\-]?(a|b)', 'tokens', 'once');
    if ~isempty(hit)
        dom = upper(string(hit{1}));
        return;
    end
end
end


%% ========================================================================
function sid = infer_session_id(base, fullpath)
sid = string(base);
p = strsplit(string(fullpath), filesep);
for i = numel(p):-1:1
    token = lower(strtrim(p{i}));
    if token == "" || token == "." || token == ".."
        continue;
    end
    if startsWith(token, "session") || startsWith(token, "sess")
        sid = string(p{i});
        return;
    end
end
end


%% ========================================================================
function anchor = infer_anchor_label(fullpath, base)
anchor = string(base);
p = strsplit(string(fullpath), filesep);
for i = numel(p):-1:1
    token = strtrim(string(p{i}));
    t = lower(token);
    if token == "" || token == "." || token == ".."
        continue;
    end
    if t == "a" || t == "b" || startsWith(t, "receiver")
        continue;
    end
    if startsWith(t, "session") || startsWith(t, "sess")
        continue;
    end
    anchor = token;
    return;
end
end
