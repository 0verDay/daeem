/**
 * config.js —— 全局可调参数（数值平衡都集中在这里）
 */

export const CONFIG = {
  // ---- 网格 ----
  // 地块**数量不变**（仍是 24 × 16），但每格像素尺寸调大 → 地图整体变大、单位相对地块很小。
  // 地图世界尺寸 = mapCols × cell = 24 × 120 = 2880 px 宽、1920 px 高。
  cell: 120,           // 单个地块边长（像素）
  mapCols: 24,         // 地图列数（x 方向）
  mapRows: 16,         // 地图行数（y 方向）
  edgePad: 48,         // 视野边缘留白

  // ---- 视野 / 相机 ----
  camera: {
    minScale: 0.18,      // 缩到最小可以看完整张地图
    maxScale: 1.6,
    startScale: 1,       // 开局缩放（1 = 一个地块 120px）
    keyPanSpeed: 900,    // 键盘平移速度（屏幕像素 / 秒）
    edgeScroll: true,    // 鼠标推到视野边缘即平移视角
    edgeSize: 44,        // 触发边缘滚动的边距（屏幕像素）
    edgeMaxSpeed: 1500,  // 贴住边缘时的最大滚动速度（屏幕像素 / 秒）
  },

  // ---- 资源 ----
  resource: {
    foodPerTilePerSec: 1,    // 每块己方地块每秒产出粮食
    goldPerTilePerSec: 1,    // 每块己方地块每秒产出黄金
    startFood: 0,
    startGold: 0,
    decimals: 1,             // HUD 上显示到小数点后几位
  },

  // ---- 单位 ----
  unit: {
    speed: 2.4,          // 基础移动速度（地块 / 秒）
    forestMult: 0.5,     // 站在森林里时速度倍率
    hpMax: 200,
    // 单位绘制半径相对地块很小：cell=120 时约占地块宽度的 1/5
    radiusFactor: 0.1,   // 半径 = 地块边长 × 该系数
    radius: 12,          // 兜底值（仅在 radiusFactor 缺失时使用）
    hitPad: 6,           // 鼠标点选单位的额外容差（像素）
  },

  // ---- 战斗 / 警戒 ----
  // 单位会攻击敌对阵营的单位；**能走直线就走直线**的移动逻辑见 path.js 的 smoothPath。
  combat: {
    enabled: true,        // false = 关闭全部单位的攻击与警戒（只剩移动，便于单独调试）
    aggroRange: 4,        // 警戒半径（格）：静止且没有目标的单位在此范围内发现敌人
    leashFactor: 1.8,     // 脱离系数：目标离“警戒起点”超过 aggroRange × 该系数就放弃追击
    repathSec: 0.3,       // 追击时两次重新寻路之间的最短间隔（秒），避免每帧重算
    flashSec: 0.22,       // 攻击特效 / 攻击线持续时间（秒，只影响渲染）
    buildingDamage: 40,   // 单位每次攻击建筑的伤害（攻击间隔沿用该单位的 cooldownSec）
    general: { damage: 26, range: 1, cooldownSec: 0.9 },   // 将领：近战
    enemy: { damage: 10, range: 1, cooldownSec: 1.2 },     // 测试敌人：近战（拆墙 40/1.2s ≈ 33 dps）
  },

  // ---- 区块占领（占位规则，后续按地图编辑器细化） ----
  zone: {
    zoneCols: 6,         // 把整张地图横向均分成几个区块
    zoneRows: 4,         // 纵向均分成几个区块
    captureTimeSec: 4,   // 己方单位站在无主区块内持续多久完成占领
    decayPerSec: 0.6,    // 无己方单位在区块内时，占领进度每秒回退多少（进度归一化 0~1）
    // 建筑也会给所在区块贡献归属：该标志为 true 表示区块内存在己方建筑即视为己方领地
    zoneOwnedByBuilding: true,
  },

  /**
   * ---- 对战（pvp）规则 ----
   *
   * 单机模式**不使用**这里的任何一项（保持 v0.3 行为：大本营不可摧毁、单位死了就没了）。
   * 联机模式下这些开关让「两个玩家分阵营打一场」成立。
   * 全部可在控制台运行时改：RTS.CONFIG.pvp.respawnSec = 0
   */
  pvp: {
    /**
     * 是否需要「双方准备」才开战。
     *   true（默认）→ 进房间后先停在准备界面：显示双方阵营、谁准备好了，
     *                  **双方都点准备**才真正开始，并有一个 3 秒倒计时。
     *   false        → 进房间就直接开打（旧的即开即打行为）
     *
     * 准备界面不只是个门面 —— 它顺带解决了「房主先进房间、客机还没到」这段窗口：
     * 只有一个人在场时永远不会开战，也就不会出现「一打开就判 P1 赢」。
     */
    requireReady: true,

    /** 准备就绪后的倒数秒数（0 = 不倒数，立即开打） */
    countdownSec: 3,

    /** 对战总时长上限（秒）。到点按「大本营剩余血量比例」判胜负，防止无限拖时间。0 = 不限时 */
    timeLimitSec: 600,

    /**
     * 大本营是否可被摧毁。
     *   false（默认）→ 血量保底 1，永远打不掉 —— 单机行为，旧测试依赖它
     *   true         → 可以打掉，且**打掉某一方大本营 = 该方落败**（这就是胜负条件）
     */
    destructibleBase: false,

    /**
     * 单位阵亡后多少秒在自家大本营复活。
     *   0 → 不复活（单机行为，死了就没了）
     *   8 → 对战推荐值：阵亡 8 秒后满血复活，节奏不至于一边倒
     *
     * ⚠️ 注意这是**无限复活**：所以胜负**只能靠拆家**，不能靠杀光对方单位。
     * ⚠️ 只在联机模式生效 —— 由 main.js 在进入联机时把 state.pvpEnabled 置为 true。
     *    单机保持 v0.3 行为（死了就是没了），否则旧测试与单机手感都会被改写。
     */
    respawnSec: 8,

    /** 复活位置从大本营往外扩几格（多单位错开，不叠在同一格） */
    respawnSpreadTiles: 1,
  },

  // ---- 建筑 ----
  building: {
    // 建造暂时免费（cost 全 0）；后续要做消耗直接改这里 + 打开 CONFIG.economy.enabled
    wall: {
      id: 'wall', name: '城墙', hotkey: 'B', cost: { food: 0, gold: 0 },
      hpMax: 300,
      color: '#7d7466', desc: '填满整个地块；己方单位可穿过，敌方单位不可进入',
    },
    tower: {
      id: 'tower', name: '箭塔', hotkey: 'T', cost: { food: 0, gold: 0 },
      damage: 12, range: 3, cooldown: 0.8,
      color: '#8d6e63', desc: '对范围内最近的敌人造成单体伤害',
    },
    base: {
      id: 'base', name: '大本营', hotkey: null, cost: null,
      hpMax: 1000, color: '#4a90d9', desc: '开局自带，不可建造、不可拆除',
    },
  },
  economy: { enabled: false },   // false = 建造不校验/不扣资源

  // ---- 调试 ----
  debug: {
    enabled: true,               // 显示调试面板（本版没有正式敌人，用它刷测试敌人验证箭塔/城墙）
    enemySpeed: 1.8,
    enemyHp: 60,
    spawnIntervalSec: 3,
  },

  colors: {
    grass: '#33422f',
    grassAlt: '#2f3d2c',
    forest: '#24402a',
    mountain: '#4c4a45',
    mountainEdge: '#5f5c55',
    grid: 'rgba(255,255,255,0.055)',
    gridStrong: 'rgba(255,255,255,0.12)',
    zoneLine: 'rgba(255,255,255,0.10)',
    zoneNeutral: 'rgba(230,190,80,0.05)',
    zonePlayer: 'rgba(90,200,255,0.13)',
    zoneProgress: 'rgba(230,190,80,0.30)',
    hq: '#3f7fd0',
    hqLight: '#6ea8e8',
    wall: '#8b8172',
    wallDark: '#5f594e',
    tower: '#a1887f',
    general: '#ffd166',
    generalSel: '#fff2b0',
    enemy: '#e05a5a',

    /**
     * ★ 阵营配色表（多人联机用）。
     * 注意 'player' 必须与 general 同为黄色 —— 单机模式下阵营就是 'player'，
     * 这样联机改造不会让单机观感发生任何变化。
     * 四个玩家席位颜色刻意拉开色相（黄 / 蓝 / 绿 / 紫），地图缩小时也能一眼分清。
     */
    faction: {
      player: { main: '#ffd166', sel: '#fff2b0', bar: '#7ce07c', line: 'rgba(255,225,150,' },
      p1: { main: '#ffd166', sel: '#fff2b0', bar: '#7ce07c', line: 'rgba(255,225,150,' },
      p2: { main: '#5ac8ff', sel: '#c9ecff', bar: '#5ac8ff', line: 'rgba(120,200,255,' },
      p3: { main: '#8ce08c', sel: '#d6ffd6', bar: '#8ce08c', line: 'rgba(140,224,140,' },
      p4: { main: '#c9a0ff', sel: '#e8d9ff', bar: '#c9a0ff', line: 'rgba(201,160,255,' },
      enemy: { main: '#e05a5a', sel: '#ffb0b0', bar: '#e05a5a', line: 'rgba(255,120,120,' },
    },
    range: 'rgba(255,209,102,0.10)',
    rangeEdge: 'rgba(255,209,102,0.45)',
  },
};

export const RESOURCES = ['food', 'gold'];
export const RESOURCE_LABEL = { food: '粮食', gold: '黄金' };
